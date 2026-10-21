# Isolated tests. No real ChatGPT processes, user configuration, or desktop are touched.
[CmdletBinding()]
param([string]$TestRoot = (Join-Path ([IO.Path]::GetTempPath()) ('gpt-sc-test-' + [guid]::NewGuid().ToString('N'))))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'GptShortcuts.Core.ps1')
$script:GptDesktopInteropPath = Join-Path $PSScriptRoot 'GptDesktopInterop.cs'

function Assert-True { param([bool]$Value, [string]$Message); if (-not $Value) { throw "Assertion failed: $Message" } }
function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $threw = $false
    try { & $Action } catch { $threw = $true }
    Assert-True $threw $Message
}
function New-Fixture {
    param([string]$Name)
    $directory = Join-Path $TestRoot $Name
    if ([IO.Directory]::Exists($directory)) { throw "Test fixture already exists; choose a new TestRoot: $directory" }
    [void][IO.Directory]::CreateDirectory($directory)
    $ctx = [pscustomobject]@{
        BindingPath=(Join-Path $directory 'keybindings.json')
        ShortcutPath=(Join-Path $directory 'ChatGPT.lnk')
    }
    return $ctx
}
function New-TestAdapter {
    return @{
        CheckShortcut = { param($ctx) }
        WriteShortcut = { param($ctx) [IO.File]::WriteAllText($ctx.ShortcutPath, 'test shortcut Alt+Shift+O') }
        VerifyShortcut = { param($ctx) [pscustomobject]@{ Matches=([IO.File]::ReadAllText($ctx.ShortcutPath) -eq 'test shortcut Alt+Shift+O') } }
        VerifyActivation = { param($ctx) [pscustomobject]@{ Matches=$true; Outcome='Verified'; Method='IsolatedAdapter' } }
    }
}

[void][IO.Directory]::CreateDirectory($TestRoot)
$passed = New-Object Collections.Generic.List[string]

$ctx = New-Fixture 'merge'
$original = '[{"command":"globalDictationHold","key":"Ctrl+P","extra":{"case":"unchanged"}},{"command":"showWorkspaceTabView","key":"Alt+Shift+O"},{"command":"realtimeVoice","key":null},{"command":"custom.command","key":"Ctrl+9","CaseSensitive":1,"casesensitive":2}]'
[IO.File]::WriteAllText($ctx.BindingPath, $original)
$entries = Read-GptBindings $ctx.BindingPath
$merged = Merge-GptBindings $entries
Assert-True ($entries[0]['key'] -eq 'Ctrl+P') 'merge does not modify input snapshot'
Assert-True ($merged.Count -eq 6) 'targets are upserted once'
Assert-True ($merged[0]['extra']['case'] -eq 'unchanged') 'unknown target fields survive'
Assert-True ($null -eq $merged[2]['key']) 'explicit null disabling survives'
Assert-True ($merged[3]['CaseSensitive'] -eq 1 -and $merged[3]['casesensitive'] -eq 2) 'case-sensitive unknown fields survive'
Write-GptBindings $ctx.BindingPath $merged
$once = [IO.File]::ReadAllText($ctx.BindingPath)
Write-GptBindings $ctx.BindingPath (Merge-GptBindings (Read-GptBindings $ctx.BindingPath))
Assert-True ($once -ceq [IO.File]::ReadAllText($ctx.BindingPath)) 'second run is idempotent'
$report = Get-GptBindingReport (Read-GptBindings $ctx.BindingPath)
Assert-True (-not $report.Matches) 'matching targets still fail verification while desktop conflicts remain'
Assert-True ($report.DesktopHotkeyConflicts.Count -eq 1 -and $report.DesktopHotkeyConflicts[0] -eq 'showWorkspaceTabView') 'Alt+Shift+O conflict is preserved and reported'
$passed.Add('merge, unknown fields, nulls, conflict preservation, idempotence')

$catalogDefaults = @(
    [pscustomobject]@{Command='defaultOccupant'; TitleIntlId='codex.command.defaultOccupant'; DefaultKeys=@('Control+Shift+N','Alt+9')},
    [pscustomobject]@{Command='disabledDefault'; TitleIntlId='codex.command.disabledDefault'; DefaultKeys=@('Ctrl+Shift+N')}
)
$conflictEntries = @(@{command='existingOccupant';key=' shift + ALT + o ';extra=7}, @{command='disabledDefault';key=$null})
$resolution = Resolve-GptBindingConflicts $conflictEntries ([ordered]@{newTask='Shift+Ctrl+N'}) 'Alt+Shift+O' $catalogDefaults
Assert-True ($resolution.RemovedConflicts.Count -eq 2) 'explicit and implicit default occupants are both removed'
$resolved = Merge-GptBindings $conflictEntries $resolution.Desired
Assert-True ((Get-GptBindingReport $resolved $resolution.Desired 'Alt+Shift+O' $catalogDefaults).Matches) 'cleanup leaves no effective conflicts'
Assert-True ($resolved[0]['extra'] -eq 7 -and $null -eq $resolved[0]['key']) 'disabled occupant retains unknown fields'
Assert-True ($resolution.RemovedConflicts[0].PSObject.Properties['TitleIntlId'] -ne $null) 'removed commands include function name lookup metadata'
Assert-True ((Resolve-GptBindingConflicts $resolved ([ordered]@{newTask='Ctrl+Shift+N'}) 'Alt+Shift+O' $catalogDefaults).RemovedConflicts.Count -eq 0) 'cleanup is idempotent and null suppresses defaults'
Assert-Throws { Resolve-GptBindingConflicts @() ([ordered]@{a='Ctrl+N';b='N+Control'}) $null } 'two requested commands cannot occupy the same key'
Assert-Throws { Resolve-GptBindingConflicts @() ([ordered]@{a='Alt+Shift+O'}) 'Shift+Alt+O' } 'requested app and desktop keys must be distinct'
$passed.Add('forced cleanup, default occupants, normalized keys, null defaults, request collisions')

foreach ($bad in @('null','{}','[1]','[{"command":"x"}]','[{"command":"focusMainChat","key":"A"},{"command":"focusMainChat","key":"B"}]','[broken')) {
    [IO.File]::WriteAllText($ctx.BindingPath, $bad)
    Assert-Throws { Read-GptBindings $ctx.BindingPath } "invalid JSON/schema: $bad"
    Assert-True ([IO.File]::ReadAllText($ctx.BindingPath) -ceq $bad) 'invalid input remains unchanged'
}
$ctxEmpty = New-Fixture 'empty'
$empty = Read-GptBindings $ctxEmpty.BindingPath
Assert-True ($empty.Count -eq 0) 'absent keybindings is an empty array'
Write-GptBindings $ctxEmpty.BindingPath (Merge-GptBindings $empty)
Assert-True ((Read-GptBindings $ctxEmpty.BindingPath).Count -eq 4) 'absent keybindings can be initialized'
$initialBindings = Read-GptBindings $ctxEmpty.BindingPath
$initialMap = @{}
foreach ($entry in $initialBindings) { $initialMap[$entry['command']] = $entry['key'] }
Assert-True ($initialMap['composer.startVoiceMode'] -ceq 'Alt+Shift+I') 'voice startup uses the composer command'
Assert-True ($initialMap['globalDictationHold'] -ceq 'Alt+Shift+U') 'hold dictation uses U'
Assert-True ($initialMap.ContainsKey('realtimeVoice') -and $null -eq $initialMap['realtimeVoice']) 'realtime shortcut is explicitly disabled'
Assert-True ($initialMap['realtimeVoice.toggleMicrophoneMute'] -ceq 'Alt+Shift+P') 'microphone mute uses P'
Assert-True (-not $initialMap.ContainsKey('focusMainChat') -and -not $initialMap.ContainsKey('hotkeyWindow')) 'focus and companion window are not preset overrides'
$passed.Add('invalid and duplicate input rejection, missing file initialization')

$ctx = New-Fixture 'success'
[IO.File]::WriteAllText($ctx.BindingPath, $original)
[IO.File]::WriteAllText($ctx.ShortcutPath, 'original shortcut')
$adapter = New-TestAdapter
# Forbidden lifecycle hooks prove applying settings does not require app shutdown or launch.
$adapter.Stop = { param($ctx) throw 'MUST NOT stop ChatGPT' }
$adapter.Start = { param($ctx) throw 'MUST NOT launch ChatGPT' }
$adapter.Running = { param($ctx) throw 'MUST NOT inspect app lifecycle' }
$result = Invoke-GptTransaction $ctx $adapter (Join-Path (Split-Path $ctx.BindingPath) 'run')
Assert-True ($result.State -eq 'Succeeded' -and $result.RestartRequired) 'success requests manual restart without app lifecycle calls'
Assert-True ($result.Message -like '*manually*') 'success includes explicit manual restart reminder'
Assert-True ($result.RemovedConflicts.Count -eq 1 -and $result.RemovedConflicts[0].Command -eq 'showWorkspaceTabView') 'success reports the removed conflicting function'
Assert-True ($null -eq @((Read-GptBindings $ctx.BindingPath) | Where-Object { $_['command'] -eq 'showWorkspaceTabView' })[0]['key']) 'desktop occupant is disabled on disk'
Assert-True ([IO.File]::Exists((Join-Path $result.BackupDirectory 'ChatGPT.lnk'))) 'existing shortcut is backed up'
Assert-True (@((Read-GptBindings $ctx.BindingPath) | Where-Object { $_['command'] -ceq 'custom.command' }).Count -eq 1) 'unrelated settings survive'
$passed.Add('successful synchronous apply, backups, manual restart reminder, no app lifecycle calls')

foreach ($existing in @($true,$false)) {
    $ctx = New-Fixture ('rollback-' + $existing)
    if ($existing) {
        [IO.File]::WriteAllText($ctx.BindingPath, $original)
        [IO.File]::WriteAllText($ctx.ShortcutPath, 'original shortcut bytes')
    }
    $adapter = New-TestAdapter
    $adapter.VerifyShortcut = { param($ctx) [pscustomobject]@{Matches=$false} }
    $result = Invoke-GptTransaction $ctx $adapter (Join-Path (Split-Path $ctx.BindingPath) 'run')
    Assert-True ($result.State -eq 'Failed' -and $result.Restored -and -not $result.RestartRequired) 'read-back failure restores without a restart reminder'
    if ($existing) {
        Assert-True ([IO.File]::ReadAllText($ctx.BindingPath) -ceq $original) 'rollback restores original binding bytes'
        Assert-True ([IO.File]::ReadAllText($ctx.ShortcutPath) -ceq 'original shortcut bytes') 'rollback restores shortcut bytes'
    }
    else {
        Assert-True (-not [IO.File]::Exists($ctx.BindingPath) -and -not [IO.File]::Exists($ctx.ShortcutPath)) 'rollback removes only newly created files'
    }
}
$passed.Add('read-back failure rollback for existing and absent files')

$ctx = New-Fixture 'write-failure'
[IO.File]::WriteAllText($ctx.BindingPath, $original)
$adapter = New-TestAdapter
$adapter.WriteShortcut = { param($ctx) throw 'simulated shortcut write failure' }
$result = Invoke-GptTransaction $ctx $adapter (Join-Path (Split-Path $ctx.BindingPath) 'run')
Assert-True ($result.State -eq 'Failed' -and $result.Restored -and -not $result.RestartRequired) 'write failure rolls back without app lifecycle actions'
Assert-True ([IO.File]::ReadAllText($ctx.BindingPath) -ceq $original) 'write failure restores exact configuration'
$passed.Add('partial write failure rollback')

$ctx = New-Fixture 'shortcut-collision'
[IO.File]::WriteAllText($ctx.BindingPath, $original)
[IO.File]::WriteAllText($ctx.ShortcutPath, 'other app')
$adapter = New-TestAdapter
$adapter.CheckShortcut = { param($ctx) throw 'other application owns ChatGPT.lnk' }
$adapter.Stop = { param($ctx) throw 'MUST NOT stop on preflight collision' }
$result = Invoke-GptTransaction $ctx $adapter (Join-Path (Split-Path $ctx.BindingPath) 'run')
Assert-True ($result.State -eq 'Failed' -and $result.Stage -eq 'Preflight') 'shortcut collision rejected before writing'
Assert-True ([IO.File]::ReadAllText($ctx.ShortcutPath) -ceq 'other app') 'other app shortcut untouched'
$passed.Add('shortcut collision blocks writes')

# Import only function definitions from the entrypoint, without executing its dispatcher.
$tokens = $null; $parseErrors = $null
$entrypoint = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Set-GptShortcuts.ps1'), [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'entrypoint parses under Windows PowerShell 5.1'
foreach ($name in @('Get-GptShortcut','Assert-GptShortcutOwner','Set-GptShortcut','Test-GptShortcut','Assert-GptRequestedCommands','Get-GptJsObject','Get-GptCommandDefaults','Initialize-GptDesktopInterop','Send-GptShortcutNotification','Test-GptDesktopActivation','Complete-GptDesktopPlan')) {
    $definition = $entrypoint.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]}, $false) | Where-Object { $_.Name -eq $name }
    . ([scriptblock]::Create($definition.Extent.Text))
}
$defaultObject = '{id:`test`,browser:{defaultKeybindings:[{key:`Alt+B`}]},electron:{defaultKeybindings:[{key:`Alt+E`}],platformDefaultKeybindings:{macOS:[],default:[{key:`Ctrl+Shift+]`},{key:`Control+\``}]}}}'
$parsedKeys = Get-GptCommandDefaults $defaultObject
Assert-True ($parsedKeys.Count -eq 2 -and $parsedKeys[0] -ceq 'Ctrl+Shift+]' -and $parsedKeys[1] -ceq 'Control+`') 'Windows defaults parse brackets and escaped backticks without browser defaults'
Assert-True ((Get-GptCommandDefaults '{electron:{defaultKeybindings:[{key:`Alt+E`}],platformDefaultKeybindings:{windows:[]}}}').Count -eq 0) 'empty Windows defaults override common defaults'
$passed.Add('installed command default extraction, platform selection, literal string escapes')
Initialize-GptDesktopInterop
Assert-True (([GptDesktopInterop]::ParseHotkey('Alt+Shift+O') -join ',') -eq '18,16,79') 'native verifier parses modifier and key codes'
Assert-Throws { [GptDesktopInterop]::ParseHotkey('Alt+F12') } 'reserved F12 is rejected before mutation'
$passed.Add('native desktop verifier compiles under Windows PowerShell 5.1 and validates keys')
$ctx = New-Fixture 'real-link'
$linkContext = [pscustomobject]@{
    Desktop=(Split-Path -Parent $ctx.ShortcutPath); ShortcutPath=$ctx.ShortcutPath
    AppPath=(Join-Path $env:WINDIR 'explorer.exe'); AppId='Test.App_abc!App'
    ShortcutTarget=(Join-Path $env:WINDIR 'explorer.exe'); ShortcutArguments='shell:AppsFolder\Test.App_abc!App'
    IconLocation=((Join-Path $env:WINDIR 'explorer.exe') + ',0')
}
Assert-GptShortcutOwner $linkContext
Set-GptShortcut $linkContext
Assert-True (Test-GptShortcut $linkContext).Matches 'real COM shortcut preserves Alt+Shift+O and app activation target'
Assert-GptShortcutOwner $linkContext
Set-GptShortcut $linkContext
Assert-True (Test-GptShortcut $linkContext).Matches 'existing shortcut is replaced and read back correctly'
$hashBefore = (Get-FileHash -LiteralPath $ctx.ShortcutPath -Algorithm SHA256).Hash
$linkContext.ShortcutArguments = 'shell:AppsFolder\Other.App_xyz!App'
Assert-Throws { Assert-GptShortcutOwner $linkContext } 'different application shortcut owner rejected'
Assert-True ((Get-FileHash -LiteralPath $ctx.ShortcutPath -Algorithm SHA256).Hash -eq $hashBefore) 'ownership check is read only'
$passed.Add('real Windows COM shortcut properties, replacement, ownership protection in a temp directory')

$linkContext.ShortcutArguments = 'shell:AppsFolder\Test.App_abc!App'
$linkContext | Add-Member -NotePropertyName DesktopHotkey -NotePropertyValue 'Alt+Shift+K'
$script:RefreshStates = @()
Set-GptShortcut $linkContext -Notify {
    param($path, $created)
    $wsh = New-Object -ComObject WScript.Shell
    $script:RefreshStates += [pscustomobject]@{Path=$path;Hotkey=$wsh.CreateShortcut($path).Hotkey;Created=$created}
}
Assert-True (Test-GptShortcut $linkContext).Matches 'custom desktop hotkey survives real COM read-back'
Assert-True ($script:RefreshStates.Count -eq 2 -and $script:RefreshStates[0].Hotkey -eq '' -and (ConvertTo-GptKeyIdentity $script:RefreshStates[1].Hotkey) -eq (ConvertTo-GptKeyIdentity 'Alt+Shift+K')) 'refresh saves empty and target keys at the actual path before notification'
Assert-True (@($script:RefreshStates | Where-Object { $_.Path -cne $ctx.ShortcutPath }).Count -eq 0) 'refresh never registers a temporary shortcut'
$linkContext.DesktopHotkey = ''
Set-GptShortcut $linkContext
Assert-True ((Test-GptShortcut $linkContext).Matches -and (Get-GptShortcut $linkContext).Hotkey -eq '') 'desktop hotkey can be disabled without deleting the shortcut'
$passed.Add('custom desktop hotkey and disabling in a temp directory')

$existingPlan = [pscustomobject]@{ManageDesktop=$false;HasChanges=$false;DesktopHotkey=$null}
$linkContext.DesktopHotkey = 'Alt+Shift+K'
Set-GptShortcut $linkContext
$completed = Complete-GptDesktopPlan $existingPlan $linkContext
Assert-True ($completed.ManageDesktop -and $completed.HasChanges -and (ConvertTo-GptKeyIdentity $completed.DesktopHotkey) -eq (ConvertTo-GptKeyIdentity 'Alt+Shift+K')) 'every Apply checks desktop while retaining its customized hotkey'
$passed.Add('desktop refresh plan preserves the existing hotkey without resetting app presets')

$ctx = New-Fixture 'first-initialization'
$initializationPath = Join-Path (Split-Path $ctx.BindingPath) 'gpt-sc.initialized.json'
$custom = @(@{command='focusMainChat';key='Alt+K'}, @{command='newTask';key='Alt+N'})
$plan = Get-GptChangePlan $initializationPath $custom
Assert-True ($plan.Initialize -and $plan.ManageDesktop -and $plan.Desired.Count -eq 6) 'first Apply includes presets and extra requested commands'
Assert-True ($plan.Desired['focusMainChat'] -eq 'Alt+K') 'explicit first-run focus binding is included'
$overridePlan = Get-GptChangePlan $initializationPath @(@{command='globalDictationHold';key='Alt+K'})
Assert-True ($overridePlan.Desired['globalDictationHold'] -ceq 'Alt+K') 'explicit first-run choice overrides preset'
$adapter = New-TestAdapter
$result = Invoke-GptTransaction $ctx $adapter (Join-Path (Split-Path $ctx.BindingPath) 'run') -Plan $plan
Assert-True ($result.State -eq 'Succeeded' -and [IO.File]::Exists($initializationPath)) 'successful initialization records completion'
$laterPlan = Get-GptChangePlan $initializationPath
Assert-True (-not $laterPlan.Initialize -and -not $laterPlan.ManageDesktop -and -not $laterPlan.HasChanges -and $laterPlan.Desired.Count -eq 0) 'later empty request never reapplies presets'
$adapter.Stop = { param($ctx) throw 'MUST NOT stop on no-op' }
$noop = Invoke-GptTransaction $ctx $adapter (Join-Path (Split-Path $ctx.BindingPath) 'noop-run') -Plan $laterPlan
Assert-True ($noop.State -eq 'Succeeded' -and $noop.Stage -eq 'NoChanges' -and -not $noop.RestartRequired) 'later empty request does not ask for a restart'
Assert-True (-not [IO.Directory]::Exists((Join-Path (Split-Path $ctx.BindingPath) 'noop-run'))) 'no-op creates no backups'
$passed.Add('first-run presets, explicit override, persistent initialization, later no-op')

# Subsequent requests must not reset presets or touch a foreign desktop link.
$newRequested = @(@{command='newTask';key='Ctrl+Shift+N'}, @{command='realtimeVoice';key=$null})
$plan = Get-GptChangePlan $initializationPath $newRequested
Assert-True (-not $plan.Initialize -and -not $plan.ManageDesktop -and $plan.Desired.Count -eq 2) 'subsequent plan includes only requested commands'
[IO.File]::WriteAllText($ctx.ShortcutPath, 'user customized desktop link')
$adapter = New-TestAdapter
$adapter.CheckShortcut = { param($ctx) throw 'MUST NOT inspect unrequested desktop ownership' }
$adapter.WriteShortcut = { param($ctx) throw 'MUST NOT rewrite unrequested desktop link' }
$adapter.VerifyShortcut = { param($ctx) throw 'MUST NOT verify unrequested desktop link' }
$result = Invoke-GptTransaction $ctx $adapter (Join-Path (Split-Path $ctx.BindingPath) 'custom-run') -Plan $plan
Assert-True ($result.State -eq 'Succeeded') 'custom request succeeds independently of desktop link'
$bindings = Read-GptBindings $ctx.BindingPath
Assert-True ((Get-GptBindingReport $bindings $plan.Desired $null).Matches) 'custom change and explicit null match'
$focus = @($bindings | Where-Object { $_['command'] -ceq 'focusMainChat' })
Assert-True ($focus.Count -eq 1 -and $focus[0]['key'] -ceq 'Alt+K') 'customized preset was not reset'
Assert-True ([IO.File]::ReadAllText($ctx.ShortcutPath) -ceq 'user customized desktop link') 'unrequested desktop link is unchanged'
$passed.Add('subsequent arbitrary commands, null disabling, unrequested settings preservation')

$adapter.WriteShortcut = { param($ctx) throw 'MUST NOT touch desktop on failure either' }

$beforeCustomFailure = [IO.File]::ReadAllText($ctx.BindingPath)
$script:VerificationFailureInjected = $false
$result = Invoke-GptTransaction $ctx $adapter (Join-Path (Split-Path $ctx.BindingPath) 'custom-failure-run') -Plan $plan -Progress { param($state) if ($state.Stage -eq 'Verifying' -and -not $script:VerificationFailureInjected) { $script:VerificationFailureInjected = $true; throw 'simulated verification failure' } }
Assert-True ($result.State -eq 'Failed' -and $result.Restored) 'custom request can roll back'
Assert-True ([IO.File]::ReadAllText($ctx.BindingPath) -ceq $beforeCustomFailure) 'custom rollback restores bindings'
Assert-True ([IO.File]::ReadAllText($ctx.ShortcutPath) -ceq 'user customized desktop link') 'custom rollback does not restore unrequested desktop link'
Assert-True ([IO.File]::Exists($initializationPath)) 'custom failure does not remove earlier initialization record'
$passed.Add('custom failure restores only managed files and retains initialization')

$ctx = New-Fixture 'initialization-failure'
$initializationPath = Join-Path (Split-Path $ctx.BindingPath) 'gpt-sc.initialized.json'
$plan = Get-GptChangePlan $initializationPath
$adapter = New-TestAdapter
$adapter.VerifyShortcut = { param($ctx) [pscustomobject]@{ Matches=$false } }
$result = Invoke-GptTransaction $ctx $adapter (Join-Path (Split-Path $ctx.BindingPath) 'run') -Plan $plan
Assert-True ($result.State -eq 'Failed' -and $result.Restored -and -not [IO.File]::Exists($initializationPath)) 'failed first apply leaves no initialization marker'
Assert-True (Get-GptChangePlan $initializationPath).Initialize 'failed initialization is retryable'
[IO.File]::WriteAllText($initializationPath, '{}')
Assert-Throws { Get-GptChangePlan $initializationPath } 'invalid marker cannot silently reapply presets'
$passed.Add('failed initialization remains retryable and invalid marker is rejected')

$catalog = @([pscustomobject]@{Command='newTask'}, [pscustomobject]@{Command='realtimeVoice'})
Assert-GptRequestedCommands $newRequested $catalog
Assert-Throws { Assert-GptRequestedCommands @(@{command='invented.command';key='Ctrl+1'}) $catalog } 'unknown command rejected before exit'
Assert-Throws { Get-GptChangePlan (Join-Path $TestRoot 'uncreated-marker.json') @(@{command='newTask';key=''}) } 'blank custom key rejected'
$desktopPlan = Get-GptChangePlan (Join-Path $TestRoot 'first-initialization\gpt-sc.initialized.json') @() $true 'Alt+Shift+K'
Assert-True ($desktopPlan.ManageDesktop -and $desktopPlan.Desired.Count -eq 0 -and $desktopPlan.DesktopHotkey -eq 'Alt+Shift+K') 'later desktop-only request does not reapply app presets'
$passed.Add('installed-command validation and empty custom key rejection')

$ctx = New-Fixture 'desktop-only-default-conflict'
$desktopPlan = [pscustomobject]@{Initialize=$false; InitializationPath=$null; Desired=[ordered]@{}; ManageDesktop=$true; DesktopHotkey='Alt+Shift+O'; HasChanges=$true}
$desktopCatalog = @([pscustomobject]@{Command='showWorkspaceTabView';TitleIntlId='codex.command.showWorkspaceTabView';DefaultKeys=@('Shift+Alt+O')})
$result = Invoke-GptTransaction $ctx (New-TestAdapter) (Join-Path (Split-Path $ctx.BindingPath) 'run') -Plan $desktopPlan -Catalog $desktopCatalog
Assert-True ($result.State -eq 'Succeeded' -and $result.RemovedConflicts.Count -eq 1) 'desktop-only apply removes implicit defaults even with no requested app commands'
Assert-True ($null -eq (Read-GptBindings $ctx.BindingPath)[0]['key']) 'implicit default is suppressed with a persistent null override'
$passed.Add('desktop-only transaction cleans implicit defaults')

$ctx = New-Fixture 'conflict-reintroduced'
[IO.File]::WriteAllText($ctx.BindingPath, $original)
$script:ConflictPath = $ctx.BindingPath
$result = Invoke-GptTransaction $ctx (New-TestAdapter) (Join-Path (Split-Path $ctx.BindingPath) 'run') -Progress {
    param($state)
    if ($state.Stage -eq 'Verifying') {
        $bindings = Read-GptBindings $script:ConflictPath
        Write-GptBindings $script:ConflictPath (Merge-GptBindings $bindings ([ordered]@{showWorkspaceTabView='Alt+Shift+O'}))
    }
}
Assert-True ($result.State -eq 'Failed' -and $result.Restored -and $result.RemovedConflicts.Count -eq 0) 'remaining conflict fails read-back and does not claim cleanup success'
Assert-True ([IO.File]::ReadAllText($ctx.BindingPath) -ceq $original) 'conflict read-back failure restores exact original bindings'
$passed.Add('reintroduced conflict fails verification and rolls back cleanup')

$ctx = New-Fixture 'activation-failure'
[IO.File]::WriteAllText($ctx.BindingPath, $original)
[IO.File]::WriteAllText($ctx.ShortcutPath, 'original shortcut bytes')
$adapter = New-TestAdapter
$script:ActivationAttempts = 0
$script:RollbackNotified = $false
$adapter.VerifyActivation = {param($ctx) $script:ActivationAttempts++; [pscustomobject]@{Matches=$false;Outcome='Inconclusive: desktop unavailable'}}
$adapter.NotifyRestoredShortcut = {param($ctx) $script:RollbackNotified = $true}
$result = Invoke-GptTransaction $ctx $adapter (Join-Path (Split-Path $ctx.BindingPath) 'run')
Assert-True ($result.State -eq 'Failed' -and $result.Restored -and -not $result.RestartRequired -and $script:ActivationAttempts -eq 2) 'correct shortcut properties cannot pass without a verified activation; only one retry'
Assert-True ([IO.File]::ReadAllText($ctx.ShortcutPath) -ceq 'original shortcut bytes' -and $script:RollbackNotified) 'activation failure restores shortcut and notifies the Shell'
Assert-True ([IO.File]::ReadAllText($ctx.BindingPath) -ceq $original) 'activation failure restores app bindings too'
$passed.Add('activation failure and inconclusive result block success and roll back after one retry')

$ctx = New-Fixture 'activation-retry-success'
$adapter = New-TestAdapter
$script:ActivationAttempts = 0
$adapter.VerifyActivation = {param($ctx) $script:ActivationAttempts++; [pscustomobject]@{Matches=($script:ActivationAttempts -eq 2);Outcome='Verified'}}
$result = Invoke-GptTransaction $ctx $adapter (Join-Path (Split-Path $ctx.BindingPath) 'run')
Assert-True ($result.State -eq 'Succeeded' -and $script:ActivationAttempts -eq 2 -and $result.Verification.DesktopActivation.Matches) 'one refresh retry can recover activation and is recorded'
$passed.Add('activation recovery retry succeeds only with runtime evidence')

[pscustomobject]@{ State='Passed'; Groups=$passed.Count; Tests=$passed.ToArray(); TestRoot=$TestRoot } | ConvertTo-Json -Depth 5
