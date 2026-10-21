# Requires Windows PowerShell 5.1. This file is ASCII for reliable -File decoding.
[CmdletBinding()]
param(
    [ValidateSet('Preview','Apply','Verify')][string]$Mode = 'Preview',
    [string]$AppPath,
    [string]$ConfigRoot,
    [string]$BindingsFile,
    [AllowEmptyString()][string]$DesktopHotkey,
    [switch]$ListCommands,
    [string]$RunRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'GptShortcuts.Core.ps1')
$script:GptDesktopInteropPath = Join-Path $PSScriptRoot 'GptDesktopInterop.cs'

function Get-GptJsObject {
    param([string]$Source, [int]$Start, [char]$Opening = '{', [char]$Closing = '}')
    $depth = 0; $quote = [char]0
    for ($i = $Start; $i -lt $Source.Length; $i++) {
        $c = $Source[$i]
        if ($quote -ne [char]0) {
            if ($c -eq '\') { $i++; continue }
            if ($c -eq $quote) { $quote = [char]0 }
            continue
        }
        if ($c -eq '"' -or $c -eq "'" -or $c -eq '`') { $quote = $c; continue }
        if ($c -eq $Opening) { $depth++ }
        if ($c -eq $Closing) {
            $depth--
            if ($depth -eq 0) { return $Source.Substring($Start, $i - $Start + 1) }
        }
    }
    throw 'Cannot read command object from this app version.'
}

function Get-GptCommandDefaults {
    param([string]$CommandObject)
    $electron = [regex]::Match($CommandObject, '\belectron\s*:\s*\{')
    if (-not $electron.Success) { return ,@() }
    $block = Get-GptJsObject $CommandObject ($electron.Index + $electron.Length - 1)
    $defaults = [regex]::Match($block, '\bdefaultKeybindings\s*:\s*\[')
    $keySource = $block
    $platform = [regex]::Match($block, '\bplatformDefaultKeybindings\s*:\s*\{')
    if ($platform.Success) {
        $platformBlock = Get-GptJsObject $block ($platform.Index + $platform.Length - 1)
        $windows = [regex]::Match($platformBlock, '\bwindows\s*:\s*\[', 'IgnoreCase')
        if (-not $windows.Success) { $windows = [regex]::Match($platformBlock, '\bdefault\s*:\s*\[') }
        if ($windows.Success) { $defaults = $windows; $keySource = $platformBlock }
    }
    if (-not $defaults.Success) {
        if ($block -match '\bdefaultKeybindings\s*:') { throw 'Unsupported dynamic default keybindings; refusing incomplete conflict detection.' }
        return ,@()
    }
    $array = Get-GptJsObject $keySource ($defaults.Index + $defaults.Length - 1) '[' ']'
    $keys = @([regex]::Matches($array, '\bkey\s*:\s*(?<quote>[`"''])(?<key>(?:\\.|(?!\k<quote>).)*)\k<quote>') | ForEach-Object {
        $_.Groups['key'].Value -replace '\\([\\`"''])','$1'
    })
    if ($array -notmatch '^\[\s*\]$' -and $keys.Count -eq 0) { throw 'Cannot read default shortcut keys for this app version.' }
    return ,$keys
}

function Assert-GptAppSchema {
    param([string]$Executable, [switch]$Catalog)
    $asar = Join-Path (Split-Path -Parent $Executable) 'resources\app.asar'
    if (-not [IO.File]::Exists($asar)) { throw 'Unsupported app: resources/app.asar was not found.' }
    $stream = [IO.File]::OpenRead($asar)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        $prefix = $reader.ReadBytes(16)
        if ($prefix.Length -ne 16) { throw 'Invalid ASAR header.' }
        $headerSize = [BitConverter]::ToUInt32($prefix, 12)
        if ($headerSize -gt 16777216) { throw 'Unsupported ASAR header size.' }
        $headerBytes = $reader.ReadBytes($headerSize)
        if ($headerBytes.Length -ne $headerSize) { throw 'Incomplete ASAR header.' }
        $header = (New-GptJsonSerializer).DeserializeObject([Text.Encoding]::UTF8.GetString($headerBytes))
        $files = $header['files']['.vite']['files']['build']['files']
        $supported = $false
        $commands = New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
        foreach ($name in $files.Keys) {
            if ($name -notmatch '^(main|src)-.*\.js$') { continue }
            $entry = $files[$name]
            if (-not $entry.ContainsKey('offset') -or [long]$entry['size'] -gt 16777216) { continue }
            [void]$stream.Seek((8L + [BitConverter]::ToUInt32($prefix, 4) + [long]$entry['offset']), [IO.SeekOrigin]::Begin)
            $source = [Text.Encoding]::UTF8.GetString($reader.ReadBytes([int]$entry['size']))
            if ($source.Contains('globalDictationHold') -and $source.Contains('focusMainChat') -and
                $source.Contains('hotkeyWindow') -and $source.Contains('keybindings.json')) {
                $supported = $true
            }
            if ($Catalog) {
                foreach ($match in [regex]::Matches($source, '\bid:\s*[`"'']([^`"'']+)[`"'']\s*,\s*titleIntlId:\s*[`"'']([^`"'']+)[`"'']')) {
                    if ($match.Groups[2].Value.StartsWith('codex.command.')) {
                        $objectStart = $source.LastIndexOf('{', $match.Index)
                        $commandObject = Get-GptJsObject $source $objectStart
                        try { $defaultKeys = Get-GptCommandDefaults $commandObject }
                        catch { throw ($match.Groups[1].Value + ': ' + $_.Exception.Message) }
                        $commands[$match.Groups[1].Value] = [pscustomobject]@{
                            Command=$match.Groups[1].Value; TitleIntlId=$match.Groups[2].Value
                            DefaultKeys=$defaultKeys
                        }
                    }
                }
            }
            elseif ($supported) { break }
        }
        if (-not $supported) { throw 'This app version does not expose the supported keybindings.json commands.' }
        if ($Catalog) {
            if ($commands.Count -eq 0) { throw 'Cannot read the command catalog for this app version.' }
            return ,@($commands.Values | Sort-Object Command)
        }
    }
    finally { $reader.Dispose(); $stream.Dispose() }
}

function Resolve-GptContext {
    param([string]$ExplicitApp, [string]$ExplicitConfig)
    if ($env:OS -ne 'Windows_NT') { throw 'Windows is required.' }
    $running = @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | ForEach-Object {
        try { if ($_.Path) { $_.Path } } catch { }
    } | Sort-Object -Unique)
    $candidates = @()
    if ($ExplicitApp) { $candidates = @([IO.Path]::GetFullPath($ExplicitApp)) }
    elseif ($running.Count -eq 1) { $candidates = $running }
    elseif ($running.Count -gt 1) { throw ('Multiple running installations; specify -AppPath: ' + ($running -join ', ')) }
    else {
        try {
            $packages = @(Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop)
            foreach ($package in $packages) {
                $exe = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
                if ([IO.File]::Exists($exe)) { $candidates += $exe }
            }
        } catch { Write-Verbose ('AppX discovery unavailable: ' + $_.Exception.Message) }
        foreach ($relative in @('Programs\ChatGPT\ChatGPT.exe','Programs\Codex\ChatGPT.exe')) {
            $exe = Join-Path $env:LOCALAPPDATA $relative
            if ([IO.File]::Exists($exe)) { $candidates += $exe }
        }
        # A stable existing shortcut can locate a registered Store app even if AppX cmdlets fail.
        if ($candidates.Count -eq 0) {
            $shell = New-Object -ComObject Shell.Application
            $folder = $shell.Namespace('shell:AppsFolder')
            if ($null -ne $folder) {
                foreach ($item in $folder.Items()) {
                    $id = [string]$item.ExtendedProperty('System.AppUserModel.ID')
                    if ($id -like 'OpenAI.Codex_*!App') {
                        $pattern = 'OpenAI.Codex_*__' + ($id.Split('!')[0] -replace '^OpenAI\.Codex_','')
                        $windowsApps = Join-Path $env:ProgramFiles 'WindowsApps'
                        foreach ($dir in @(Get-ChildItem -LiteralPath $windowsApps -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $pattern })) {
                            $exe = Join-Path $dir.FullName 'app\ChatGPT.exe'
                            if ([IO.File]::Exists($exe)) { $candidates += $exe }
                        }
                    }
                }
            }
        }
    }
    $candidates = @($candidates | Sort-Object -Unique)
    if ($candidates.Count -ne 1) { throw ('Cannot uniquely locate ChatGPT. Specify -AppPath. Candidates: ' + ($candidates -join ', ')) }
    $exe = $candidates[0]
    if (-not [IO.File]::Exists($exe) -or [IO.Path]::GetFileName($exe) -ine 'ChatGPT.exe') { throw "Invalid ChatGPT executable: $exe" }
    $script:GptCommandCatalog = Assert-GptAppSchema $exe -Catalog
    if (-not $ExplicitConfig) {
        if ($env:CODEX_HOME) { $ExplicitConfig = $env:CODEX_HOME }
        else {
            $profileDirectory = [Environment]::GetFolderPath('UserProfile')
            if (-not $profileDirectory) { $profileDirectory = $env:USERPROFILE }
            if (-not $profileDirectory) { throw 'Cannot resolve the current user profile; specify -ConfigRoot.' }
            $ExplicitConfig = Join-Path $profileDirectory '.codex'
        }
    }
    $config = [IO.Path]::GetFullPath($ExplicitConfig)
    if (-not [IO.Directory]::Exists($config)) { throw "Config directory not found: $config" }
    $desktop = [Environment]::GetFolderPath('DesktopDirectory')
    if (-not $desktop -or -not [IO.Directory]::Exists($desktop)) { throw 'The current user desktop directory is unavailable.' }
    $appId = $null
    $manifest = Join-Path (Split-Path -Parent (Split-Path -Parent $exe)) 'AppxManifest.xml'
    if ([IO.File]::Exists($manifest)) {
        [xml]$xml = [IO.File]::ReadAllText($manifest)
        $identity = $xml.SelectSingleNode('/*[local-name()="Package"]/*[local-name()="Identity"]')
        $app = $xml.SelectSingleNode('/*[local-name()="Package"]/*[local-name()="Applications"]/*[local-name()="Application"][@Id="App"]')
        $folderName = Split-Path -Leaf (Split-Path -Parent $manifest)
        if ($null -ne $identity -and $null -ne $app -and $identity.GetAttribute('Name') -eq 'OpenAI.Codex' -and $folderName -match '__([^_]+)$') {
            $appId = $identity.GetAttribute('Name') + '_' + $Matches[1] + '!' + $app.GetAttribute('Id')
        }
    }
    $target = $exe; $arguments = ''
    if ($appId) { $target = Join-Path $env:WINDIR 'explorer.exe'; $arguments = 'shell:AppsFolder\' + $appId }
    $icon = Join-Path (Split-Path -Parent $exe) 'resources\icon-chatgpt.ico'
    if (-not [IO.File]::Exists($icon)) { $icon = $exe }
    return [pscustomobject]@{
        AppPath=$exe; AppId=$appId; ConfigRoot=$config
        BindingPath=(Join-Path $config 'keybindings.json')
        InitializationPath=(Join-Path $config 'gpt-sc.initialized.json')
        Desktop=$desktop; ShortcutPath=(Join-Path $desktop 'ChatGPT.lnk')
        ShortcutTarget=$target; ShortcutArguments=$arguments; IconLocation=($icon + ',0')
    }
}

function Assert-GptRequestedCommands {
    param([AllowEmptyCollection()][object[]]$Entries, [object[]]$Catalog)
    foreach ($entry in $Entries) {
        if (@($Catalog | Where-Object { $_.Command -ceq $entry['command'] }).Count -ne 1) {
            throw ('Unknown command for this installation: ' + $entry['command'] + '. Use -ListCommands first.')
        }
    }
}

function Get-GptShortcut {
    param($Context)
    if (-not [IO.File]::Exists($Context.ShortcutPath)) { return $null }
    $wsh = New-Object -ComObject WScript.Shell
    $link = $wsh.CreateShortcut($Context.ShortcutPath)
    return [pscustomobject]@{ TargetPath=$link.TargetPath; Arguments=$link.Arguments; Hotkey=$link.Hotkey; IconLocation=$link.IconLocation }
}

function Assert-GptShortcutOwner {
    param($Context)
    if ([IO.Directory]::Exists($Context.ShortcutPath)) { throw 'ChatGPT.lnk is a directory; refusing to overwrite it.' }
    $link = Get-GptShortcut $Context
    if ($null -eq $link) { return }
    $sameApp = ($link.TargetPath -ieq $Context.AppPath -and [string]::IsNullOrWhiteSpace($link.Arguments))
    $sameRegisteredApp = ($Context.AppId -and $link.TargetPath -ieq $Context.ShortcutTarget -and $link.Arguments -ieq $Context.ShortcutArguments)
    if (-not ($sameApp -or $sameRegisteredApp)) { throw 'Existing ChatGPT.lnk targets a different or unrecognized application; it was not overwritten.' }
}

function Set-GptShortcut {
    param($Context, [scriptblock]$Notify = { param($path, $created) Send-GptShortcutNotification $path $created })
    $wsh = New-Object -ComObject WScript.Shell
    $created = -not [IO.File]::Exists($Context.ShortcutPath)
    $requestedHotkey = 'Alt+Shift+O'
    if ($null -ne $Context.PSObject.Properties['DesktopHotkey']) { $requestedHotkey = [string]$Context.DesktopHotkey }
    $link = $wsh.CreateShortcut($Context.ShortcutPath)
    # Save at the final path so Explorer sees the hotkey being removed and re-added.
    # Replacing a temporary .lnk only proves file contents, not Shell registration.
    if ($created) {
        $link.TargetPath = $Context.ShortcutTarget
        $link.Arguments = $Context.ShortcutArguments
        $link.WorkingDirectory = Split-Path -Parent $Context.AppPath
        $link.IconLocation = $Context.IconLocation
        $link.Description = 'ChatGPT'
    }
    $link.Hotkey = ''
    $link.Save()
    & $Notify $Context.ShortcutPath $created
    if ($requestedHotkey) {
        Start-Sleep -Milliseconds 350
        $link = $wsh.CreateShortcut($Context.ShortcutPath)
        $link.Hotkey = $requestedHotkey
        $link.Save()
        & $Notify $Context.ShortcutPath $false
    }
}

function Initialize-GptDesktopInterop {
    if (-not ('GptDesktopInterop' -as [type])) {
        Add-Type -Path $script:GptDesktopInteropPath -ReferencedAssemblies System,System.Windows.Forms,System.Drawing
    }
}

function Send-GptShortcutNotification {
    param([string]$Path, [bool]$Created = $false)
    Initialize-GptDesktopInterop
    [GptDesktopInterop]::Notify($Path, $Created)
}

function Test-GptDesktopActivation {
    param($Context)
    Initialize-GptDesktopInterop
    $outcome = [GptDesktopInterop]::CheckActivation($Context.AppPath, $Context.DesktopHotkey, 8000)
    return [pscustomobject]@{ Matches=($outcome -ceq 'Verified'); Outcome=$outcome; Method='HotkeyToForegroundWindow' }
}

function Complete-GptDesktopPlan {
    param($Plan, $Context)
    # Every Apply refreshes and verifies the desktop hotkey, without resetting app presets.
    Assert-GptShortcutOwner $Context
    if (-not $Plan.ManageDesktop) {
        $link = Get-GptShortcut $Context
        $Plan.DesktopHotkey = 'Alt+Shift+O'
        if ($null -ne $link) { $Plan.DesktopHotkey = [string]$link.Hotkey }
        $Plan.ManageDesktop = $true
        $Plan.HasChanges = $true
    }
    $Context | Add-Member -NotePropertyName DesktopHotkey -NotePropertyValue $Plan.DesktopHotkey -Force
    if ($Plan.DesktopHotkey) {
        Initialize-GptDesktopInterop
        [void][GptDesktopInterop]::ParseHotkey($Plan.DesktopHotkey)
    }
    return $Plan
}

function Test-GptShortcut {
    param($Context)
    $link = Get-GptShortcut $Context
    $matches = $false
    $expectedHotkey = 'Alt+Shift+O'
    if ($null -ne $Context.PSObject.Properties['DesktopHotkey']) { $expectedHotkey = [string]$Context.DesktopHotkey }
    if ($null -ne $link) {
        $hotkey = (($link.Hotkey.ToUpperInvariant() -replace '\s','').Split('+') | Sort-Object) -join '+'
        $expected = (($expectedHotkey.ToUpperInvariant() -replace '\s','').Split('+') | Sort-Object) -join '+'
        $matches = ($link.TargetPath -ieq $Context.ShortcutTarget -and $link.Arguments -ieq $Context.ShortcutArguments -and $hotkey -eq $expected)
    }
    return [pscustomobject]@{ Matches=$matches; ExpectedHotkey=$expectedHotkey; Actual=$link }
}

function Write-GptRunStatus {
    param([string]$Directory, $State, $Context)
    $record = [ordered]@{ UpdatedAt=[DateTimeOffset]::Now.ToString('o'); Result=$State; Context=$Context }
    Write-GptAtomicText (Join-Path $Directory 'status.json') ($record | ConvertTo-Json -Depth 20)
    $line = '{0} State={1} Stage={2}' -f $record.UpdatedAt, $State.State, $State.Stage
    if ($State.Error) { $line += ' Error=' + $State.Error }
    [IO.File]::AppendAllText((Join-Path $Directory 'execution.log'), ($line + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
}

$RunDirectory = $null
try {
    $context = Resolve-GptContext $AppPath $ConfigRoot
    if ($ListCommands) {
        if ($Mode -eq 'Apply' -or $BindingsFile -or $PSBoundParameters.ContainsKey('DesktopHotkey')) { throw '-ListCommands must be used on its own with a read-only mode.' }
        $script:GptCommandCatalog | ConvertTo-Json -Depth 4
        exit 0
    }
    $requestedBindings = @()
    if ($BindingsFile) {
        $requestedPath = [IO.Path]::GetFullPath($BindingsFile)
        if (-not [IO.File]::Exists($requestedPath)) { throw "Bindings file not found: $requestedPath" }
        $requestedBindings = Read-GptBindings $requestedPath
        Assert-GptRequestedCommands $requestedBindings $script:GptCommandCatalog
    }
    $desktopSpecified = $PSBoundParameters.ContainsKey('DesktopHotkey')
    if ($DesktopHotkey -ieq 'None') { $DesktopHotkey = '' }
    $plan = Get-GptChangePlan $context.InitializationPath $requestedBindings $desktopSpecified $DesktopHotkey
    if ($Mode -eq 'Apply') { $plan = Complete-GptDesktopPlan $plan $context }
    $context | Add-Member -NotePropertyName DesktopHotkey -NotePropertyValue $plan.DesktopHotkey -Force
    $entries = Read-GptBindings $context.BindingPath
    $resolution = Resolve-GptBindingConflicts $entries $plan.Desired $plan.DesktopHotkey $script:GptCommandCatalog
    $shortcutReport = [pscustomobject]@{ Matches=$true; Skipped=$true; Actual=(Get-GptShortcut $context) }
    if ($plan.ManageDesktop) { Assert-GptShortcutOwner $context; $shortcutReport = Test-GptShortcut $context }
    $report = [ordered]@{
        Mode=$Mode; Context=$context
        FirstRun=$plan.Initialize; HasChanges=$plan.HasChanges; CurrentEntries=$entries
        CurrentBindings=(Get-GptBindingReport $entries $plan.Desired $plan.DesktopHotkey $script:GptCommandCatalog)
        PlannedBindings=(Get-GptBindingReport (Merge-GptBindings $entries $resolution.Desired) $resolution.Desired $plan.DesktopHotkey $script:GptCommandCatalog)
        RemovedConflicts=$resolution.RemovedConflicts
        Shortcut=$shortcutReport
        Note='Conflicting app bindings are explicitly disabled. Read-back is not proof of actual hotkey behavior.'
    }
    if ($Mode -ne 'Apply') {
        $report | ConvertTo-Json -Depth 20
        if ($Mode -eq 'Verify' -and (-not $report.CurrentBindings.Matches -or -not $report.Shortcut.Matches)) { exit 1 }
        exit 0
    }
    if (-not $plan.HasChanges) {
        [pscustomobject]@{ State='NoChanges'; RestartRequired=$false; Message='GPT-SC is already initialized. Specify -BindingsFile or -DesktopHotkey to change shortcuts. Presets were not reapplied.' } | ConvertTo-Json
        exit 0
    }

    if (-not $RunRoot) { $RunRoot = Join-Path $env:LOCALAPPDATA 'GPT-SC\runs' }
    $runId = [DateTime]::Now.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $RunDirectory = Join-Path ([IO.Path]::GetFullPath($RunRoot)) $runId
    [void][IO.Directory]::CreateDirectory($RunDirectory)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $mutex = New-Object Threading.Mutex($false, ('Local\GPT-SC-' + $sid))
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another GPT-SC Apply operation is active for this user.' }
        $plan = Get-GptChangePlan $context.InitializationPath $requestedBindings $desktopSpecified $DesktopHotkey
        $plan = Complete-GptDesktopPlan $plan $context
        $context | Add-Member -NotePropertyName DesktopHotkey -NotePropertyValue $plan.DesktopHotkey -Force
        $adapter = @{
            CheckShortcut = { param($ctx) Assert-GptShortcutOwner $ctx }
            WriteShortcut = { param($ctx) Set-GptShortcut $ctx }
            VerifyShortcut = { param($ctx) Test-GptShortcut $ctx }
            VerifyActivation = { param($ctx) Test-GptDesktopActivation $ctx }
            NotifyRestoredShortcut = { param($ctx) Initialize-GptDesktopInterop; [GptDesktopInterop]::NotifyRestored($ctx.ShortcutPath) }
        }
        $progress = { param($state) Write-GptRunStatus $RunDirectory $state $context }
        $result = Invoke-GptTransaction $context $adapter $RunDirectory $progress -Plan $plan -Catalog $script:GptCommandCatalog
        [pscustomobject]@{
            State=$result.State; RestartRequired=$result.RestartRequired; Message=$result.Message
            RemovedConflicts=$result.RemovedConflicts
            RunDirectory=$RunDirectory; StatusPath=(Join-Path $RunDirectory 'status.json'); Result=$result
        } | ConvertTo-Json -Depth 20
        if ($result.State -ne 'Succeeded') { exit 1 }
    }
    finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
    exit 0
}
catch {
    $message = $_.Exception.Message
    Write-Verbose $_.ScriptStackTrace
    if ($Mode -eq 'Apply' -and $RunDirectory -and [IO.Directory]::Exists($RunDirectory)) {
        try { Write-GptRunStatus $RunDirectory @{ State='Failed'; Stage='Preflight'; Error=$message } $null } catch { }
    }
    [Console]::Error.WriteLine($message)
    exit 1
}
