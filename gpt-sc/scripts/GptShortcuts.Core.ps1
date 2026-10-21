# PowerShell 5.1 compatible. Functions only: dot-sourcing performs no application actions.
Set-StrictMode -Version 2.0

function Get-GptDesiredBindings {
    return [ordered]@{
        'composer.startVoiceMode' = 'Alt+Shift+I'
        globalDictationHold = 'Alt+Shift+U'
        realtimeVoice = $null
        'realtimeVoice.toggleMicrophoneMute' = 'Alt+Shift+P'
    }
}

function New-GptJsonSerializer {
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = 16777216
    $serializer.RecursionLimit = 100
    return $serializer
}

function Read-GptBindings {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { return ,@() }
    $text = [IO.File]::ReadAllText($Path)
    if (-not $text.TrimStart().StartsWith('[')) { throw "Keybindings must be a JSON array: $Path" }
    $entries = (New-GptJsonSerializer).DeserializeObject($text)
    if ($entries -isnot [Array]) { throw "Invalid keybindings array: $Path" }
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($entry in $entries) {
        if ($entry -isnot [Collections.IDictionary] -or
            -not $entry.ContainsKey('command') -or $entry['command'] -isnot [string] -or
            [string]::IsNullOrWhiteSpace($entry['command']) -or -not $entry.ContainsKey('key') -or
            ($null -ne $entry['key'] -and $entry['key'] -isnot [string])) {
            throw "Unsupported keybinding entry: $Path"
        }
        $command = $entry['command']
        if (-not $seen.Add($command)) { throw "Duplicate command: $command" }
    }
    return ,$entries
}

function Merge-GptBindings {
    param([AllowEmptyCollection()][object[]]$Entries, [Collections.IDictionary]$Desired = (Get-GptDesiredBindings))
    # Clone so callers retain the unmodified snapshot, including unknown entry fields.
    $serializer = New-GptJsonSerializer
    $merged = New-Object Collections.Generic.List[object]
    foreach ($entry in $Entries) { $merged.Add($serializer.DeserializeObject($serializer.Serialize($entry))) }
    foreach ($pair in $Desired.GetEnumerator()) {
        $existing = @($merged | Where-Object { $_['command'] -ceq $pair.Key })
        if ($existing.Count -gt 1) { throw "Duplicate target command: $($pair.Key)" }
        if ($existing.Count -eq 1) { $existing[0]['key'] = $pair.Value }
        else { $merged.Add(@{ command = $pair.Key; key = $pair.Value }) }
    }
    return ,($merged.ToArray())
}

function ConvertTo-GptKeyIdentity {
    param([AllowNull()][string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key)) { return '' }
    $parts = ($Key -replace '\s','').ToLowerInvariant().Split('+') | ForEach-Object {
        switch ($_) {
            { $_ -in @('cmdorctrl','commandorcontrol','control') } { 'ctrl'; break }
            'option' { 'alt'; break }
            { $_ -in @('super','meta','windows') } { 'win'; break }
            default { $_ }
        }
    }
    return (($parts | Sort-Object) -join '+')
}

function Get-GptEffectiveBindings {
    param([AllowEmptyCollection()][object[]]$Entries, [object[]]$Catalog = @())
    $effective = New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach ($item in $Catalog) {
        $keys = @()
        if ($null -ne $item.PSObject.Properties['DefaultKeys']) { $keys = @($item.DefaultKeys) }
        $effective[$item.Command] = [pscustomobject]@{ Command=$item.Command; Keys=$keys; TitleIntlId=$item.TitleIntlId }
    }
    foreach ($entry in $Entries) {
        $title = $null
        if ($effective.ContainsKey($entry['command'])) { $title = $effective[$entry['command']].TitleIntlId }
        $keys = @()
        if (-not [string]::IsNullOrWhiteSpace($entry['key'])) { $keys = @($entry['key']) }
        $effective[$entry['command']] = [pscustomobject]@{ Command=$entry['command']; Keys=$keys; TitleIntlId=$title }
    }
    return ,@($effective.Values)
}

function Resolve-GptBindingConflicts {
    param([AllowEmptyCollection()][object[]]$Entries, [Collections.IDictionary]$Desired,
        [AllowNull()][string]$DesktopHotkey, [object[]]$Catalog = @())
    $reserved = @{}
    if ($DesktopHotkey) { $reserved[(ConvertTo-GptKeyIdentity $DesktopHotkey)] = '<desktop>' }
    $resolved = New-Object Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
    foreach ($pair in $Desired.GetEnumerator()) {
        $resolved[$pair.Key] = $pair.Value
        $key = ConvertTo-GptKeyIdentity $pair.Value
        if (-not $key) { continue }
        if ($reserved.ContainsKey($key)) { throw "Requested shortcuts conflict: $($pair.Key) / $($reserved[$key]). Choose distinct shortcuts." }
        $reserved[$key] = $pair.Key
    }
    $removed = @()
    $merged = Merge-GptBindings $Entries $Desired
    foreach ($item in (Get-GptEffectiveBindings $merged $Catalog)) {
        if ($Desired.Contains($item.Command)) { continue }
        $occupied = @($item.Keys | Where-Object { $reserved.ContainsKey((ConvertTo-GptKeyIdentity $_)) })
        if ($occupied.Count -gt 0) {
            # An explicit null suppresses defaults; deleting an override would restore them.
            $resolved[$item.Command] = $null
            $removed += [pscustomobject]@{ Command=$item.Command; TitleIntlId=$item.TitleIntlId; PreviousKeys=@($item.Keys) }
        }
    }
    return [pscustomobject]@{ Desired=$resolved; RemovedConflicts=$removed }
}

function Get-GptBindingReport {
    param(
        [AllowEmptyCollection()][object[]]$Entries,
        [Collections.IDictionary]$Desired = (Get-GptDesiredBindings),
        [AllowNull()][AllowEmptyString()][string]$DesktopHotkey = 'Alt+Shift+O',
        [object[]]$Catalog = @()
    )
    $checks = @()
    foreach ($pair in $Desired.GetEnumerator()) {
        $matches = @($Entries | Where-Object { $_['command'] -ceq $pair.Key })
        $actual = $null
        if ($matches.Count -eq 1) { $actual = $matches[0]['key'] }
        $checks += [pscustomobject]@{ Command=$pair.Key; Expected=$pair.Value; Actual=$actual; Matches=($matches.Count -eq 1 -and $actual -ceq $pair.Value) }
    }
    $effective = Get-GptEffectiveBindings $Entries $Catalog
    $conflicts = @($effective | Where-Object {
        $DesktopHotkey -and @($_.Keys | Where-Object { (ConvertTo-GptKeyIdentity $_) -eq (ConvertTo-GptKeyIdentity $DesktopHotkey) }).Count -gt 0
    } | ForEach-Object { $_.Command })
    $targetConflicts = @()
    foreach ($pair in $Desired.GetEnumerator()) {
        foreach ($entry in $effective) {
            if ($pair.Value -and $entry.Command -cne $pair.Key -and
                @($entry.Keys | Where-Object { (ConvertTo-GptKeyIdentity $_) -eq (ConvertTo-GptKeyIdentity $pair.Value) }).Count -gt 0) {
                $targetConflicts += "$($pair.Key) / $($entry.Command): $($pair.Value)"
            }
        }
    }
    return [pscustomobject]@{
        Matches=(@($checks | Where-Object { -not $_.Matches }).Count -eq 0 -and $conflicts.Count -eq 0 -and $targetConflicts.Count -eq 0)
        Bindings=$checks; DesktopHotkeyConflicts=$conflicts; OtherConflicts=$targetConflicts
    }
}

function Get-GptChangePlan {
    param(
        [Parameter(Mandatory=$true)][string]$InitializationPath,
        [AllowEmptyCollection()][object[]]$RequestedBindings = @(),
        [bool]$DesktopHotkeySpecified = $false,
        [AllowNull()][AllowEmptyString()][string]$RequestedDesktopHotkey
    )
    $initialized = [IO.File]::Exists($InitializationPath)
    if ($initialized) {
        $state = (New-GptJsonSerializer).DeserializeObject([IO.File]::ReadAllText($InitializationPath))
        if ($state -isnot [Collections.IDictionary] -or -not $state.ContainsKey('Version') -or
            $state['Version'] -ne 1 -or -not $state.ContainsKey('Status') -or $state['Status'] -cne 'Initialized') {
            throw 'Invalid GPT-SC initialization record; refusing to reapply presets.'
        }
    }
    $desired = New-Object Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
    if (-not $initialized) {
        foreach ($pair in (Get-GptDesiredBindings).GetEnumerator()) { $desired.Add($pair.Key, $pair.Value) }
    }
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($entry in $RequestedBindings) {
        $command = $entry['command']
        if (-not $seen.Add($command)) { throw "Duplicate requested command: $command" }
        if ($null -ne $entry['key'] -and [string]::IsNullOrWhiteSpace($entry['key'])) { throw 'Use key: null to disable a binding, not an empty string.' }
        $desired[$command] = $entry['key']
    }
    $desktop = $null
    if (-not $initialized) { $desktop = 'Alt+Shift+O' }
    if ($DesktopHotkeySpecified) { $desktop = $RequestedDesktopHotkey }
    return [pscustomobject]@{
        Initialize=(-not $initialized); InitializationPath=$InitializationPath; Desired=$desired
        ManageDesktop=((-not $initialized) -or $DesktopHotkeySpecified); DesktopHotkey=$desktop
        HasChanges=((-not $initialized) -or $DesktopHotkeySpecified -or $desired.Count -gt 0)
    }
}

function Write-GptAtomicText {
    param([string]$Path, [string]$Text)
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temp, $Text, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    }
    finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Write-GptBindings {
    param([string]$Path, [AllowEmptyCollection()][object[]]$Entries)
    Write-GptAtomicText $Path ((New-GptJsonSerializer).Serialize([object[]]$Entries))
}

function Backup-GptFiles {
    param($Context, [string]$Directory, [bool]$ManageDesktop = $true, [string]$InitializationPath)
    [void][IO.Directory]::CreateDirectory($Directory)
    $snapshot = [pscustomobject]@{
        Directory=$Directory
        BindingExisted=[IO.File]::Exists($Context.BindingPath)
        ShortcutManaged=$ManageDesktop
        ShortcutExisted=($ManageDesktop -and [IO.File]::Exists($Context.ShortcutPath))
        InitializationPath=$InitializationPath
        InitializationExisted=($InitializationPath -and [IO.File]::Exists($InitializationPath))
    }
    if ($snapshot.BindingExisted) { [IO.File]::Copy($Context.BindingPath, (Join-Path $Directory 'keybindings.json'), $false) }
    if ($snapshot.ShortcutExisted) { [IO.File]::Copy($Context.ShortcutPath, (Join-Path $Directory 'ChatGPT.lnk'), $false) }
    if ($snapshot.InitializationExisted) { [IO.File]::Copy($InitializationPath, (Join-Path $Directory 'initialized.json'), $false) }
    Write-GptAtomicText (Join-Path $Directory 'manifest.json') ($snapshot | ConvertTo-Json)
    return $snapshot
}

function Restore-GptFiles {
    param($Context, $Snapshot)
    $errors = @()
    $items = @(@{ Path=$Context.BindingPath; Existed=$Snapshot.BindingExisted; Name='keybindings.json' })
    if ($Snapshot.ShortcutManaged) { $items += @{ Path=$Context.ShortcutPath; Existed=$Snapshot.ShortcutExisted; Name='ChatGPT.lnk' } }
    if ($Snapshot.InitializationPath) { $items += @{ Path=$Snapshot.InitializationPath; Existed=$Snapshot.InitializationExisted; Name='initialized.json' } }
    foreach ($item in $items) {
        try {
            if ($item.Existed) {
                $temp = "$($item.Path).$([guid]::NewGuid().ToString('N')).restore"
                try {
                    [IO.File]::Copy((Join-Path $Snapshot.Directory $item.Name), $temp, $false)
                    if ([IO.File]::Exists($item.Path)) { [IO.File]::Replace($temp, $item.Path, [NullString]::Value) }
                    else { [IO.File]::Move($temp, $item.Path) }
                }
                finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
            }
            elseif ([IO.File]::Exists($item.Path)) { [IO.File]::Delete($item.Path) }
        }
        catch { $errors += "$($item.Name): $($_.Exception.Message)" }
    }
    if ($errors.Count -gt 0) { throw ($errors -join '; ') }
}

function Invoke-GptTransaction {
    param($Context, $Adapter, [string]$RunDirectory, [scriptblock]$Progress = {}, $Plan = $null, [object[]]$Catalog = @())
    if ($null -eq $Plan) {
        $Plan = [pscustomobject]@{ Initialize=$false; InitializationPath=$null; Desired=(Get-GptDesiredBindings); ManageDesktop=$true; DesktopHotkey='Alt+Shift+O'; HasChanges=$true }
    }
    $result = [ordered]@{
        State='Running'; Stage='Preflight'; Error=$null; RestoreError=$null
        Restored=$false; RestartRequired=$false; Message=$null; Verification=$null; BackupDirectory=$null; RemovedConflicts=@()
    }
    $snapshot = $null; $mutated = $false
    try {
        if (-not $Plan.HasChanges) {
            $result.State = 'Succeeded'; $result.Stage = 'NoChanges'
            $result.Message = 'No changes were requested. Presets were not reapplied.'
            & $Progress $result
            return [pscustomobject]$result
        }
        $initializationPath = $null
        if ($Plan.Initialize) { $initializationPath = $Plan.InitializationPath }
        $entries = Read-GptBindings $Context.BindingPath
        $resolution = Resolve-GptBindingConflicts $entries $Plan.Desired $Plan.DesktopHotkey $Catalog
        if ($Plan.ManageDesktop) { & $Adapter.CheckShortcut $Context }
        $snapshot = Backup-GptFiles $Context (Join-Path $RunDirectory 'before-write') $Plan.ManageDesktop $initializationPath
        $result.BackupDirectory = $snapshot.Directory
        $result.Stage = 'Writing'; & $Progress $result
        $mutated = $true
        if ($resolution.Desired.Count -gt 0) { Write-GptBindings $Context.BindingPath (Merge-GptBindings $entries $resolution.Desired) }
        if ($Plan.ManageDesktop) { & $Adapter.WriteShortcut $Context }
        $result.Stage = 'Verifying'; & $Progress $result
        $bindingReport = Get-GptBindingReport (Read-GptBindings $Context.BindingPath) $resolution.Desired $Plan.DesktopHotkey $Catalog
        $shortcutReport = [pscustomobject]@{ Matches=$true; Skipped=$true }
        if ($Plan.ManageDesktop) { $shortcutReport = & $Adapter.VerifyShortcut $Context }
        $result.Verification = @{ Keybindings=$bindingReport; Shortcut=$shortcutReport }
        if (-not $bindingReport.Matches -or -not $shortcutReport.Matches) { throw 'Configuration or shortcut read-back failed.' }
        if ($Plan.ManageDesktop -and $Plan.DesktopHotkey) {
            if (-not $Adapter.ContainsKey('VerifyActivation')) { throw 'Desktop activation verification is required; no verifier was provided.' }
            $result.Stage = 'CheckingDesktopActivation'; & $Progress $result
            $activation = & $Adapter.VerifyActivation $Context
            $result.Verification['DesktopActivation'] = $activation
            if (-not $activation.Matches) {
                # One bounded retry replays clear/save/notify and restore/save/notify.
                $result.Stage = 'RetryingDesktopActivation'; & $Progress $result
                & $Adapter.WriteShortcut $Context
                $shortcutReport = & $Adapter.VerifyShortcut $Context
                $result.Verification['Shortcut'] = $shortcutReport
                if (-not $shortcutReport.Matches) { throw 'Desktop shortcut read-back failed after refresh.' }
                $activation = & $Adapter.VerifyActivation $Context
                $result.Verification['DesktopActivation'] = $activation
                if (-not $activation.Matches) { throw ('Desktop hotkey activation was not verified: ' + $activation.Outcome) }
            }
        }
        if ($Plan.Initialize) {
            Write-GptAtomicText $initializationPath (@{ Version=1; Status='Initialized'; InitializedAt=[DateTimeOffset]::Now.ToString('o') } | ConvertTo-Json)
        }
        $result.RestartRequired = $true
        $result.RemovedConflicts = $resolution.RemovedConflicts
        $result.Message = 'Settings saved. Please fully exit and reopen ChatGPT manually for the changes to take effect.'
        $result.State = 'Succeeded'; $result.Stage = 'Complete'
    }
    catch {
        $result.Error = $_.Exception.Message
        $result.State = 'Failed'
        if ($mutated -and $null -ne $snapshot) {
            try {
                Restore-GptFiles $Context $snapshot
                if ($Plan.ManageDesktop -and $Adapter.ContainsKey('NotifyRestoredShortcut')) { & $Adapter.NotifyRestoredShortcut $Context }
                $result.Restored = $true
            }
            catch { $result.RestoreError = $_.Exception.Message }
        }
    }
    & $Progress $result
    return [pscustomobject]$result
}
