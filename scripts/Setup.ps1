# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [ValidateSet("Install", "Repair", "Uninstall")]
    [string]$Mode = "Install",

    [ValidateSet("Auto", "CurrentUser", "AllUsers")]
    [string]$Scope = "Auto",

    [ValidateSet("Ask", "Yes", "No")]
    [string]$StartMenu = "Ask",

    [string]$SourceRoot,

    [switch]$Quiet,
    [switch]$Interactive,
    [switch]$RemoveUserData
)

$ErrorActionPreference = "Stop"

$ProductName = "Sierra History Bridge"
$ProductKey = "SierraHistoryBridge"
$Publisher = "Sierra History Bridge contributors"
$Version = "0.0.22"

$PowerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$UserDataRoot = Join-Path $env:LOCALAPPDATA $ProductKey
$SetupLog = Join-Path $UserDataRoot "setup.log"

New-Item -ItemType Directory -Path $UserDataRoot -Force | Out-Null

function Write-SetupLog([string]$Message) {
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -LiteralPath $SetupLog -Value "[$stamp] $Message" -Encoding UTF8
}

function Show-Header {
    Clear-Host
    Write-Host "================================================================"
    Write-Host " $ProductName Setup"
    Write-Host " Version $Version"
    Write-Host "================================================================"
    Write-Host
}

function Pause-IfInteractive {
    if ($Interactive -and -not $Quiet) {
        Write-Host
        Read-Host "Press Enter to close" | Out-Null
    }
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Quote-CommandLineArgument([string]$Value) {
    if ($null -eq $Value) { return '""' }
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Resolve-SourceRoot {
    if ($SourceRoot) {
        $resolved = [IO.Path]::GetFullPath($SourceRoot)
        if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
            throw "Setup source folder does not exist: $resolved"
        }
        return $resolved
    }

    $candidate = Split-Path -Parent $PSScriptRoot

    if ((Test-Path -LiteralPath (Join-Path $candidate "app")) -or
        (Test-Path -LiteralPath (Join-Path $candidate "src"))) {
        return $candidate
    }

    throw "Setup could not determine the source package location."
}

function Get-InstallDirectory([string]$InstallScope) {
    if ($InstallScope -eq "AllUsers") {
        return Join-Path $env:ProgramFiles $ProductName
    }

    return Join-Path (Join-Path $env:LOCALAPPDATA "Programs") $ProductName
}

function Get-StartMenuDirectory([string]$InstallScope) {
    if ($InstallScope -eq "AllUsers") {
        $programs = [Environment]::GetFolderPath("CommonPrograms")
    }
    else {
        $programs = [Environment]::GetFolderPath("Programs")
    }

    return Join-Path $programs $ProductName
}

function Get-UninstallRegistryPath([string]$InstallScope) {
    if ($InstallScope -eq "AllUsers") {
        return "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$ProductKey"
    }

    return "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$ProductKey"
}

function Get-ClassesRegistryRoot([string]$InstallScope) {
    if ($InstallScope -eq "AllUsers") {
        return "HKLM:\Software\Classes"
    }

    return "HKCU:\Software\Classes"
}

function Get-ExistingInstallation {
    foreach ($installScope in @("CurrentUser", "AllUsers")) {
        $key = Get-UninstallRegistryPath $installScope

        if (Test-Path -LiteralPath $key) {
            try {
                $entry = Get-ItemProperty -LiteralPath $key
                if ($entry.InstallLocation -and (Test-Path -LiteralPath $entry.InstallLocation)) {
                    return [pscustomobject]@{
                        Scope = $installScope
                        InstallLocation = [string]$entry.InstallLocation
                        Version = [string]$entry.DisplayVersion
                        StartMenuShortcuts = ([int]$entry.StartMenuShortcuts -eq 1)
                    }
                }
            }
            catch { }
        }
    }

    # Development builds before v0.0.22 stored program files below the mutable
    # application-data folder. Detect them so setup can migrate cleanly.
    $legacyApp = Join-Path $UserDataRoot "app"
    if (Test-Path -LiteralPath (Join-Path $legacyApp "SierraHistoryBridge.ps1")) {
        return [pscustomobject]@{
            Scope = "CurrentUser"
            InstallLocation = $legacyApp
            Version = "development"
            StartMenuShortcuts = $false
            Legacy = $true
        }
    }

    return $null
}

function Ask-NewInstallScope {
    if ($Scope -ne "Auto") {
        return $Scope
    }

    if ($Quiet) {
        return "CurrentUser"
    }

    Write-Host "Install location:"
    Write-Host
    Write-Host "  1. Current user (recommended)"
    Write-Host "     Installs under your local Programs folder and does not require"
    Write-Host "     administrator access."
    Write-Host
    Write-Host "  2. All users"
    Write-Host "     Installs under Program Files and requires administrator access."
    Write-Host

    $answer = Read-Host "Choose 1 or 2 [1]"
    if ([string]::IsNullOrWhiteSpace($answer) -or $answer -eq "1") {
        return "CurrentUser"
    }
    if ($answer -eq "2") {
        return "AllUsers"
    }

    throw "Invalid installation choice."
}

function Ask-StartMenuPreference {
    param(
        [string]$Requested,
        [object]$ExistingPreference
    )

    if ($Requested -eq "Yes") { return $true }
    if ($Requested -eq "No") { return $false }

    if ($Quiet) {
        if ($null -ne $ExistingPreference) { return [bool]$ExistingPreference }
        return $true
    }

    if ($null -ne $ExistingPreference) {
        $defaultText = if ($ExistingPreference) { "Y/n" } else { "y/N" }
        $answer = Read-Host "Create Start Menu / All apps shortcuts? [$defaultText]"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return [bool]$ExistingPreference
        }
    }
    else {
        $answer = Read-Host "Create Start Menu / All apps shortcuts? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $true
        }
    }

    $normalized = $answer.Trim().ToLowerInvariant()
    return $normalized -in @("y", "yes")
}

function Read-SetupConfig {
    $path =
        Join-Path $UserDataRoot "config.json"

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    try {
        return (
            Get-Content `
                -LiteralPath $path `
                -Raw |
            ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Get-DefaultSierraDataFolder {
    $config = Read-SetupConfig

    if ($config -and
        $config.default_data_folder -and
        (Test-Path `
            -LiteralPath ([string]$config.default_data_folder) `
            -PathType Container)) {

        return [IO.Path]::GetFullPath(
            [string]$config.default_data_folder).TrimEnd('\')
    }

    foreach ($candidate in @(
        "C:\SierraChart\Data",
        "C:\SierraChart64\Data",
        "D:\SierraChart\Data",
        "D:\SierraChart64\Data"
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return [IO.Path]::GetFullPath(
                $candidate).TrimEnd('\')
        }
    }

    return $null
}

function Read-SetupFolder(
    [string]$Label,
    [string]$Default,
    [bool]$MustExist) {

    if ($Quiet) {
        if (-not $Default) {
            throw "$Label was not specified."
        }

        return [IO.Path]::GetFullPath(
            $Default).TrimEnd('\')
    }

    Write-Host
    if ($Default) {
        Write-Host "$Label"
        Write-Host "  $Default"
        $answer =
            Read-Host "Press Enter to keep it, or paste another folder"

        if ([string]::IsNullOrWhiteSpace($answer)) {
            $answer = $Default
        }
    }
    else {
        $answer =
            Read-Host "$Label"
    }

    $resolved =
        [IO.Path]::GetFullPath(
            $answer.Trim().Trim('"')).TrimEnd('\')

    if ($MustExist -and
        -not (Test-Path -LiteralPath $resolved -PathType Container)) {

        throw "$Label does not exist: $resolved"
    }

    return $resolved
}

function Configure-UserPaths([bool]$IsRepair) {
    $existingConfig = Read-SetupConfig
    $currentData = Get-DefaultSierraDataFolder

    if (-not $currentData) {
        if ($Quiet) {
            throw "Sierra Chart Data folder could not be detected."
        }

        $currentData =
            Read-SetupFolder `
                "Sierra Chart Data folder" `
                $null `
                $true
    }

    $currentArchive =
        if ($existingConfig -and
            $existingConfig.archive_folder) {

            [IO.Path]::GetFullPath(
                [string]$existingConfig.archive_folder).TrimEnd('\')
        }
        else {
            Join-Path $currentData "SCID_Bridge_Archive"
        }

    $currentRecovery =
        if ($existingConfig -and
            $existingConfig.recovery_folder) {

            [IO.Path]::GetFullPath(
                [string]$existingConfig.recovery_folder).TrimEnd('\')
        }
        else {
            Join-Path $currentData "SCID_Bridge_Backups"
        }

    $currentLogs =
        if ($existingConfig -and
            $existingConfig.log_folder) {

            [IO.Path]::GetFullPath(
                [string]$existingConfig.log_folder).TrimEnd('\')
        }
        else {
            Join-Path $currentData "SCID_Bridge_Logs"
        }

    $changePaths = -not $IsRepair

    if ($IsRepair -and -not $Quiet) {
        Write-Host
        Write-Host "Configured Sierra folders:"
        Write-Host "  Data:     $currentData"
        Write-Host "  Archive:  $currentArchive"
        Write-Host "  Recovery: $currentRecovery"
        Write-Host "  Logs:     $currentLogs"

        $answer =
            Read-Host "Change these folders? [y/N]"

        $changePaths =
            $answer.Trim().ToLowerInvariant() -in @("y", "yes")
    }

    $data = $currentData
    $archive = $currentArchive
    $recovery = $currentRecovery
    $logs = $currentLogs

    if ($changePaths) {
        $data =
            Read-SetupFolder `
                "Sierra Chart Data folder" `
                $currentData `
                $true

        $archiveDefault =
            if ($currentArchive -and
                $currentArchive.StartsWith(
                    $currentData,
                    [StringComparison]::OrdinalIgnoreCase)) {

                Join-Path $data "SCID_Bridge_Archive"
            }
            else {
                $currentArchive
            }

        $recoveryDefault =
            if ($currentRecovery -and
                $currentRecovery.StartsWith(
                    $currentData,
                    [StringComparison]::OrdinalIgnoreCase)) {

                Join-Path $data "SCID_Bridge_Backups"
            }
            else {
                $currentRecovery
            }

        $logsDefault =
            if ($currentLogs -and
                $currentLogs.StartsWith(
                    $currentData,
                    [StringComparison]::OrdinalIgnoreCase)) {

                Join-Path $data "SCID_Bridge_Logs"
            }
            else {
                $currentLogs
            }

        $customize = $false

        if (-not $Quiet) {
            Write-Host
            $answer =
                Read-Host (
                    "Customize archive, recovery, or log folders? [y/N]")

            $customize =
                $answer.Trim().ToLowerInvariant() -in @("y", "yes")
        }

        if ($customize) {
            $archive =
                Read-SetupFolder `
                    "Archive folder" `
                    $archiveDefault `
                    $false

            $recovery =
                Read-SetupFolder `
                    "Recovery folder" `
                    $recoveryDefault `
                    $false

            $logs =
                Read-SetupFolder `
                    "Log folder" `
                    $logsDefault `
                    $false
        }
        else {
            $archive = $archiveDefault
            $recovery = $recoveryDefault
            $logs = $logsDefault
        }
    }

    $namedStorage =
        @(
            [pscustomobject]@{ Name = "Archive"; Path = $archive },
            [pscustomobject]@{ Name = "Recovery"; Path = $recovery },
            [pscustomobject]@{ Name = "Logs"; Path = $logs }
        )

    for ($i = 0; $i -lt $namedStorage.Count; $i++) {
        for ($j = $i + 1; $j -lt $namedStorage.Count; $j++) {
            $left =
                [IO.Path]::GetFullPath(
                    $namedStorage[$i].Path).TrimEnd('\')

            $right =
                [IO.Path]::GetFullPath(
                    $namedStorage[$j].Path).TrimEnd('\')

            if ($left.Equals(
                    $right,
                    [StringComparison]::OrdinalIgnoreCase) -or
                $left.StartsWith(
                    $right + '\',
                    [StringComparison]::OrdinalIgnoreCase) -or
                $right.StartsWith(
                    $left + '\',
                    [StringComparison]::OrdinalIgnoreCase)) {

                throw (
                    "$($namedStorage[$i].Name) and " +
                    "$($namedStorage[$j].Name) folders must be separate.")
            }
        }
    }

    foreach ($directory in @(
        $archive,
        $recovery,
        $logs
    )) {
        New-Item `
            -ItemType Directory `
            -Path $directory `
            -Force |
            Out-Null
    }

    $provenScales = @{}
    if ($existingConfig -and
        $existingConfig.proven_scales) {

        foreach ($property in
            $existingConfig.proven_scales.PSObject.Properties) {

            $provenScales[$property.Name] =
                $property.Value
        }
    }

    $settings =
        [ordered]@{
            proven_scales = $provenScales
            default_data_folder = $data
            archive_folder = $archive
            recovery_folder = $recovery
            log_folder = $logs
        }

    $configPath =
        Join-Path $UserDataRoot "config.json"

    $settings |
        ConvertTo-Json -Depth 8 |
        Set-Content `
            -LiteralPath $configPath `
            -Encoding UTF8

    return [pscustomobject]@{
        Data = $data
        Archive = $archive
        Recovery = $recovery
        Logs = $logs
    }
}

function New-ExplorerVerb(
    [string]$Path,
    [string]$Title,
    [string]$Command,
    [string]$Icon,
    [string]$AppliesTo) {

    New-Item -Path $Path -Force | Out-Null
    Set-Item -LiteralPath $Path -Value $Title

    if ($Icon) {
        New-ItemProperty `
            -LiteralPath $Path `
            -Name "Icon" `
            -Value $Icon `
            -PropertyType String `
            -Force |
            Out-Null
    }

    if ($AppliesTo) {
        New-ItemProperty `
            -LiteralPath $Path `
            -Name "AppliesTo" `
            -Value $AppliesTo `
            -PropertyType String `
            -Force |
            Out-Null
    }

    $commandKey =
        Join-Path $Path "command"

    New-Item -Path $commandKey -Force | Out-Null
    Set-Item -LiteralPath $commandKey -Value $Command
}

function Ensure-Elevation {
    param(
        [string]$RequestedMode,
        [string]$InstallScope,
        [bool]$CreateStartMenu,
        [string]$ResolvedSourceRoot
    )

    if ($InstallScope -ne "AllUsers" -or (Test-Administrator)) {
        return $false
    }

    if (-not (Test-Path -LiteralPath $PowerShellExe)) {
        throw "Windows PowerShell could not be found."
    }

    Write-Host
    Write-Host "Administrator approval is required for an all-users installation."

    $arguments = @(
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", (Quote-CommandLineArgument $PSCommandPath),
        "-Mode", $RequestedMode,
        "-Scope", $InstallScope,
        "-StartMenu", $(if ($CreateStartMenu) { "Yes" } else { "No" }),
        "-SourceRoot", (Quote-CommandLineArgument $ResolvedSourceRoot)
    )

    if ($Quiet) { $arguments += "-Quiet" }
    if ($Interactive) { $arguments += "-Interactive" }
    if ($RemoveUserData) { $arguments += "-RemoveUserData" }

    $argumentString = $arguments -join " "
    Write-SetupLog "Elevating: $PowerShellExe $argumentString"

    $process = Start-Process `
        -FilePath $PowerShellExe `
        -ArgumentList $argumentString `
        -Verb RunAs `
        -Wait `
        -PassThru

    exit $process.ExitCode
}

function Resolve-PayloadRoot([string]$ResolvedSourceRoot, [string]$InstallDirectory) {
    # When repair is launched from the installed copy, use the clean payload
    # archive stored with the setup files rather than copying app files over
    # themselves.
    $sourceFull = [IO.Path]::GetFullPath($ResolvedSourceRoot).TrimEnd('\')
    $installFull = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')

    if ($sourceFull -ieq $installFull) {
        $payloadZip = Join-Path $InstallDirectory "setup\payload.zip"

        if (-not (Test-Path -LiteralPath $payloadZip)) {
            throw "The repair payload is missing. Re-run setup from the release package."
        }

        $temporaryRoot = Join-Path $env:TEMP ("SierraHistoryBridge-Repair-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
        Expand-Archive -LiteralPath $payloadZip -DestinationPath $temporaryRoot -Force

        return [pscustomobject]@{
            Root = $temporaryRoot
            Temporary = $true
        }
    }

    return [pscustomobject]@{
        Root = $ResolvedSourceRoot
        Temporary = $false
    }
}

function Copy-ApplicationPayload([string]$PayloadRoot, [string]$InstallDirectory) {
    New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null

    $sourceApp =
        if (Test-Path -LiteralPath (Join-Path $PayloadRoot "app")) {
            Join-Path $PayloadRoot "app"
        }
        elseif (Test-Path -LiteralPath (Join-Path $PayloadRoot "src")) {
            Join-Path $PayloadRoot "src"
        }
        else {
            throw "The package does not contain the application source files."
        }

    $sourceSetup =
        if (Test-Path -LiteralPath (Join-Path $PayloadRoot "setup\Setup.ps1")) {
            Join-Path $PayloadRoot "setup"
        }
        elseif (Test-Path -LiteralPath (Join-Path $PayloadRoot "scripts\Setup.ps1")) {
            Join-Path $PayloadRoot "scripts"
        }
        else {
            throw "The package does not contain Setup.ps1."
        }

    foreach ($directory in @("app", "docs")) {
        $target = Join-Path $InstallDirectory $directory
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force
        }
        New-Item -ItemType Directory -Path $target -Force | Out-Null
    }

    # Setup.ps1 can be executing from this directory during Repair, so keep
    # the directory itself and replace its files in place.
    New-Item -ItemType Directory -Path (Join-Path $InstallDirectory "setup") -Force | Out-Null

    Copy-Item -LiteralPath (Join-Path $sourceApp "SierraHistoryBridge.ps1") `
        -Destination (Join-Path $InstallDirectory "app\SierraHistoryBridge.ps1") -Force

    Copy-Item -LiteralPath (Join-Path $sourceApp "ScidBridge.cs") `
        -Destination (Join-Path $InstallDirectory "app\ScidBridge.cs") -Force

    $sourceDocs = Join-Path $PayloadRoot "docs"
    if (Test-Path -LiteralPath $sourceDocs) {
        Copy-Item -Path (Join-Path $sourceDocs "*") `
            -Destination (Join-Path $InstallDirectory "docs") -Recurse -Force
    }

    Copy-Item -LiteralPath (Join-Path $sourceSetup "Setup.ps1") `
        -Destination (Join-Path $InstallDirectory "setup\Setup.ps1") -Force

    # Keep the repair payload with the installed setup files when the release
    # package provides it.
    $payloadZip = Join-Path $PayloadRoot "setup\payload.zip"
    if (Test-Path -LiteralPath $payloadZip) {
        Copy-Item -LiteralPath $payloadZip `
            -Destination (Join-Path $InstallDirectory "setup\payload.zip") -Force
    }

    foreach ($name in @(
        "README.md",
        "README.txt",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "SECURITY.md",
        "LICENSE",
        "VERSION",
        "setup.cmd",
        "run.cmd",
        "archive.cmd",
        "restore.cmd",
        "storage.cmd",
        "repair.cmd",
        "uninstall.cmd"
    )) {
        $source = Join-Path $PayloadRoot $name
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $InstallDirectory $name) -Force
        }
    }

    # Repository installs use scripts/Setup.ps1 but root launchers are already
    # present. Build-Release.ps1 provides setup/payload.zip for release builds.
}

function New-InstalledRepairPayload([string]$InstallDirectory) {
    $payloadZip = Join-Path $InstallDirectory "setup\payload.zip"
    $stage = Join-Path $env:TEMP ("SierraHistoryBridge-Payload-" + [guid]::NewGuid().ToString("N"))

    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }

    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    try {
        foreach ($directory in @("app", "docs")) {
            $source = Join-Path $InstallDirectory $directory
            if (Test-Path -LiteralPath $source) {
                Copy-Item -LiteralPath $source -Destination (Join-Path $stage $directory) -Recurse
            }
        }

        New-Item -ItemType Directory -Path (Join-Path $stage "setup") -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $InstallDirectory "setup\Setup.ps1") `
            -Destination (Join-Path $stage "setup\Setup.ps1") -Force

        foreach ($name in @(
            "README.md",
            "README.txt",
            "CHANGELOG.md",
            "LICENSE",
            "VERSION",
            "setup.cmd",
            "run.cmd",
            "archive.cmd",
            "restore.cmd",
            "storage.cmd",
            "repair.cmd",
            "uninstall.cmd"
        )) {
            $source = Join-Path $InstallDirectory $name
            if (Test-Path -LiteralPath $source) {
                Copy-Item -LiteralPath $source -Destination (Join-Path $stage $name) -Force
            }
        }

        if (Test-Path -LiteralPath $payloadZip) {
            Remove-Item -LiteralPath $payloadZip -Force
        }

        Compress-Archive `
            -Path (Join-Path $stage "*") `
            -DestinationPath $payloadZip `
            -CompressionLevel Optimal
    }
    finally {
        if (Test-Path -LiteralPath $stage) {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-InstalledPayload([string]$InstallDirectory) {
    $mainScript = Join-Path $InstallDirectory "app\SierraHistoryBridge.ps1"
    $converter = Join-Path $InstallDirectory "app\ScidBridge.cs"
    $setupScript = Join-Path $InstallDirectory "setup\Setup.ps1"

    foreach ($required in @($mainScript, $converter, $setupScript)) {
        if (-not (Test-Path -LiteralPath $required)) {
            throw "Installed file is missing: $required"
        }
    }

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $mainScript,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null

    if ($parseErrors.Count -gt 0) {
        $firstParseError = $parseErrors[0]
        $parseLine = $firstParseError.Extent.StartLineNumber
        $parseColumn = $firstParseError.Extent.StartColumnNumber

        throw (
            "The installed application script did not pass PowerShell syntax validation " +
            "at line $parseLine, column $parseColumn`: " +
            $firstParseError.Message)
    }

    # Compile the SCID engine once during installation/repair so a compiler
    # problem is discovered here rather than on first use.
    Add-Type -Path $converter
}

function Remove-ExplorerIntegration([string]$InstallScope) {
    $classesRoot =
        Get-ClassesRegistryRoot $InstallScope

    foreach ($path in @(
        "$classesRoot\Directory\shell\$ProductKey",
        "$classesRoot\Directory\shell\$ProductKey.Update",
        "$classesRoot\Directory\shell\$ProductKey.Storage",
        "$classesRoot\Directory\Background\shell\$ProductKey",
        "$classesRoot\SystemFileAssociations\.scid\shell\$ProductKey.Archive",
        "$classesRoot\SystemFileAssociations\.dly\shell\$ProductKey.Archive",
        "$classesRoot\SystemFileAssociations\.gz\shell\$ProductKey.Restore"
    )) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item `
                -LiteralPath $path `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

function Install-ExplorerIntegration(
    [string]$InstallScope,
    [string]$InstallDirectory,
    $Settings) {

    Remove-ExplorerIntegration $InstallScope

    $classesRoot =
        Get-ClassesRegistryRoot $InstallScope

    $installedScript =
        Join-Path `
            $InstallDirectory `
            "app\SierraHistoryBridge.ps1"

    $icon =
        "$env:SystemRoot\System32\shell32.dll,167"

    $dataFolder =
        [IO.Path]::GetFullPath(
            [string]$Settings.Data).TrimEnd('\')

    $archiveFolder =
        [IO.Path]::GetFullPath(
            [string]$Settings.Archive).TrimEnd('\')

    $folderAppliesTo =
        'System.ItemPathDisplay:="' +
        $dataFolder +
        '"'

    $dataFileAppliesTo =
        'System.ItemFolderPathDisplay:="' +
        $dataFolder +
        '"'

    # AQS starts-with comparison. This applies to file items; unlike
    # Directory\Background, static file verbs support AppliesTo filtering.
    $sourceArchiveFolder =
        Join-Path $archiveFolder "SC_Data"

    $archiveFileAppliesTo =
        'System.ItemPathDisplay:~<"' +
        $sourceArchiveFolder +
        '\' +
        '"'

    $baseCommand =
        '"' + $PowerShellExe + '"' +
        ' -NoLogo -NoProfile -ExecutionPolicy Bypass' +
        ' -File "' + $installedScript + '"' +
        ' -DataFolder "' + $dataFolder + '"'

    New-ExplorerVerb `
        "$classesRoot\Directory\shell\$ProductKey.Update" `
        "Update Sierra history from SC Data" `
        ($baseCommand + ' -Mode Update -Interactive') `
        $icon `
        $folderAppliesTo

    New-ExplorerVerb `
        "$classesRoot\Directory\shell\$ProductKey.Storage" `
        "Sierra History Bridge storage report" `
        ($baseCommand + ' -Mode Storage -Interactive') `
        "$env:SystemRoot\System32\shell32.dll,4" `
        $folderAppliesTo

    foreach ($extension in @(".scid", ".dly")) {
        $sourceFileAppliesTo =
            $dataFileAppliesTo +
            ' AND System.FileName:"*-*' +
            $extension +
            '"'

        New-ExplorerVerb `
            "$classesRoot\SystemFileAssociations\$extension\shell\$ProductKey.Archive" `
            "Archive SC Data source" `
            ($baseCommand + ' -Mode Archive -SelectedFile "%1" -Interactive') `
            "$env:SystemRoot\System32\shell32.dll,46" `
            $sourceFileAppliesTo
    }

    New-ExplorerVerb `
        "$classesRoot\SystemFileAssociations\.gz\shell\$ProductKey.Restore" `
        "Restore Sierra history archive" `
        ($baseCommand + ' -Mode Restore -SelectedFile "%1" -Interactive') `
        "$env:SystemRoot\System32\shell32.dll,167" `
        $archiveFileAppliesTo
}


function New-Shortcut {
    param(
        [string]$ShortcutPath,
        [string]$TargetPath,
        [string]$Arguments,
        [string]$WorkingDirectory,
        [string]$Description,
        [string]$IconLocation
    )

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $TargetPath

    if ($Arguments) { $shortcut.Arguments = $Arguments }
    if ($WorkingDirectory) { $shortcut.WorkingDirectory = $WorkingDirectory }
    if ($Description) { $shortcut.Description = $Description }
    if ($IconLocation) { $shortcut.IconLocation = $IconLocation }

    $shortcut.Save()
}

function Remove-StartMenuShortcuts([string]$InstallScope) {
    $directory = Get-StartMenuDirectory $InstallScope
    if (Test-Path -LiteralPath $directory) {
        Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-StartMenuShortcuts(
    [string]$InstallScope,
    [string]$InstallDirectory,
    [bool]$CreateShortcuts) {

    Remove-StartMenuShortcuts $InstallScope

    if (-not $CreateShortcuts) {
        return
    }

    $directory = Get-StartMenuDirectory $InstallScope
    New-Item -ItemType Directory -Path $directory -Force | Out-Null

    $mainScript = Join-Path $InstallDirectory "app\SierraHistoryBridge.ps1"
    $setupScript = Join-Path $InstallDirectory "setup\Setup.ps1"
    $readme = Join-Path $InstallDirectory "README.txt"

    New-Shortcut `
        -ShortcutPath (Join-Path $directory "$ProductName.lnk") `
        -TargetPath $PowerShellExe `
        -Arguments ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $mainScript + '" -Interactive') `
        -WorkingDirectory $InstallDirectory `
        -Description "Update Sierra Chart Rithmic history from SC Data." `
        -IconLocation "$PowerShellExe,0"

    New-Shortcut `
        -ShortcutPath (Join-Path $directory "Archive Historical Data.lnk") `
        -TargetPath $PowerShellExe `
        -Arguments ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $mainScript + '" -Mode Archive -Interactive') `
        -WorkingDirectory $InstallDirectory `
        -Description "Compress selected SC Data source files for offline archival." `
        -IconLocation "$env:SystemRoot\System32\shell32.dll,46"

    New-Shortcut `
        -ShortcutPath (Join-Path $directory "Restore Historical Data.lnk") `
        -TargetPath $PowerShellExe `
        -Arguments ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $mainScript + '" -Mode Restore -Interactive') `
        -WorkingDirectory $InstallDirectory `
        -Description "Restore archived SC Data source files to Sierra Chart." `
        -IconLocation "$env:SystemRoot\System32\shell32.dll,167"

    New-Shortcut `
        -ShortcutPath (Join-Path $directory "Storage Report.lnk") `
        -TargetPath $PowerShellExe `
        -Arguments ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $mainScript + '" -Mode Storage -Interactive') `
        -WorkingDirectory $InstallDirectory `
        -Description "Show Sierra Chart Data logical, disk, archive, recovery, and free-space usage." `
        -IconLocation "$env:SystemRoot\System32\shell32.dll,4"

    New-Shortcut `
        -ShortcutPath (Join-Path $directory "Repair $ProductName.lnk") `
        -TargetPath $PowerShellExe `
        -Arguments ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $setupScript + '" -Mode Repair -Scope ' + $InstallScope + ' -Interactive') `
        -WorkingDirectory $InstallDirectory `
        -Description "Repair the Sierra History Bridge installation." `
        -IconLocation "$env:SystemRoot\System32\shell32.dll,162"

    New-Shortcut `
        -ShortcutPath (Join-Path $directory "Uninstall $ProductName.lnk") `
        -TargetPath $PowerShellExe `
        -Arguments ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $setupScript + '" -Mode Uninstall -Scope ' + $InstallScope + ' -Interactive') `
        -WorkingDirectory $InstallDirectory `
        -Description "Uninstall Sierra History Bridge." `
        -IconLocation "$env:SystemRoot\System32\shell32.dll,131"

    if (Test-Path -LiteralPath $readme) {
        New-Shortcut `
            -ShortcutPath (Join-Path $directory "$ProductName Documentation.lnk") `
            -TargetPath (Join-Path $env:SystemRoot "System32\notepad.exe") `
            -Arguments ('"' + $readme + '"') `
            -WorkingDirectory $InstallDirectory `
            -Description "Open Sierra History Bridge documentation." `
            -IconLocation "$env:SystemRoot\System32\notepad.exe,0"
    }
}

function Get-DirectorySizeKb([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return 0
    }

    $bytes = (
        Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum
    ).Sum

    if ($null -eq $bytes) { $bytes = 0 }
    return [int][Math]::Ceiling($bytes / 1KB)
}

function Register-Uninstaller(
    [string]$InstallScope,
    [string]$InstallDirectory,
    [bool]$CreateStartMenu) {

    $key = Get-UninstallRegistryPath $InstallScope
    New-Item -Path $key -Force | Out-Null

    $setupScript = Join-Path $InstallDirectory "setup\Setup.ps1"

    $uninstallString =
        '"' + $PowerShellExe + '"' +
        ' -NoLogo -NoProfile -ExecutionPolicy Bypass' +
        ' -File "' + $setupScript + '"' +
        ' -Mode Uninstall -Scope ' + $InstallScope + ' -Interactive'

    $quietUninstallString =
        '"' + $PowerShellExe + '"' +
        ' -NoLogo -NoProfile -ExecutionPolicy Bypass' +
        ' -File "' + $setupScript + '"' +
        ' -Mode Uninstall -Scope ' + $InstallScope + ' -Quiet -RemoveUserData'

    $modifyPath =
        '"' + $PowerShellExe + '"' +
        ' -NoLogo -NoProfile -ExecutionPolicy Bypass' +
        ' -File "' + $setupScript + '"' +
        ' -Mode Repair -Scope ' + $InstallScope + ' -Interactive'

    $values = [ordered]@{
        DisplayName = $ProductName
        DisplayVersion = $Version
        Publisher = $Publisher
        InstallDate = (Get-Date -Format "yyyyMMdd")
        InstallLocation = $InstallDirectory
        DisplayIcon = "$PowerShellExe,0"
        UninstallString = $uninstallString
        QuietUninstallString = $quietUninstallString
        ModifyPath = $modifyPath
        Comments = "Updates Rithmic-named Sierra Chart intraday files with SC Data historical records."
        EstimatedSize = (Get-DirectorySizeKb $InstallDirectory)
        StartMenuShortcuts = $(if ($CreateStartMenu) { 1 } else { 0 })
        InstallScope = $InstallScope
        NoModify = 0
        NoRepair = 0
    }

    foreach ($name in $values.Keys) {
        $value = $values[$name]
        $type =
            if ($value -is [int]) { "DWord" }
            else { "String" }

        New-ItemProperty `
            -LiteralPath $key `
            -Name $name `
            -Value $value `
            -PropertyType $type `
            -Force | Out-Null
    }
}

function Remove-UninstallerRegistration([string]$InstallScope) {
    $key = Get-UninstallRegistryPath $InstallScope
    if (Test-Path -LiteralPath $key) {
        Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Remove-LegacyDevelopmentFiles {
    $legacyApp = Join-Path $UserDataRoot "app"
    $legacyRuntime = Join-Path $UserDataRoot "runtime"

    foreach ($path in @($legacyApp, $legacyRuntime)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-InstallOrRepair(
    [string]$InstallScope,
    [bool]$CreateStartMenu,
    [string]$ResolvedSourceRoot,
    [bool]$IsRepair) {

    $installDirectory = Get-InstallDirectory $InstallScope
    $payload = $null

    Write-Host
    if ($IsRepair) {
        Write-Host "Repairing $ProductName..."
    }
    else {
        Write-Host "Installing $ProductName..."
    }

    Write-Host "  Program files: $installDirectory"
    Write-Host "  User settings: $UserDataRoot"

    try {
        $payload = Resolve-PayloadRoot $ResolvedSourceRoot $installDirectory
        Copy-ApplicationPayload $payload.Root $installDirectory
        Test-InstalledPayload $installDirectory
        New-InstalledRepairPayload $installDirectory

        $settings =
            Configure-UserPaths $IsRepair

        Install-ExplorerIntegration `
            $InstallScope `
            $installDirectory `
            $settings

        Install-StartMenuShortcuts $InstallScope $installDirectory $CreateStartMenu
        Register-Uninstaller $InstallScope $installDirectory $CreateStartMenu

        Remove-LegacyDevelopmentFiles

        Write-SetupLog "$($(if ($IsRepair) { 'Repair' } else { 'Install' })) completed: scope=$InstallScope path=$installDirectory"

        Write-Host
        Write-Host "Completed successfully." -ForegroundColor Green
        Write-Host
        Write-Host "File Explorer:"
        Write-Host "  Right-click the configured Sierra Data folder for Update or Storage."
        Write-Host "  Right-click .scid/.dly source files in that folder to archive them."
        Write-Host "  Right-click bridge .gz archives to restore them."
        Write-Host "  The bridge does not add a global blank-space menu to unrelated folders."
        Write-Host
        Write-Host "Windows Settings:"
        Write-Host "  $ProductName is registered under Installed apps for standard removal."
        if ($CreateStartMenu) {
            Write-Host
            Write-Host "Start Menu / All apps:"
            Write-Host "  $ProductName"
            Write-Host "  Archive Historical Data"
            Write-Host "  Restore Historical Data"
            Write-Host "  Storage Report"
            Write-Host "  Repair $ProductName"
            Write-Host "  Uninstall $ProductName"
            Write-Host "  $ProductName Documentation"
        }
    }
    finally {
        if ($payload -and $payload.Temporary -and
            (Test-Path -LiteralPath $payload.Root)) {
            Remove-Item -LiteralPath $payload.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Ask-RemoveUserData {
    if ($RemoveUserData) {
        return $true
    }

    if ($Quiet) {
        return $true
    }

    Write-Host
    Write-Host "Saved application settings include the remembered Sierra Chart Data"
    Write-Host "folder, verified conversion scales, and processed-file state."
    $answer = Read-Host "Remove saved application settings too? [Y/n]"

    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $true
    }

    return $answer.Trim().ToLowerInvariant() -in @("y", "yes")
}

function Schedule-InstallDirectoryRemoval([string]$InstallDirectory) {
    if (-not (Test-Path -LiteralPath $InstallDirectory)) {
        return
    }

    $cleanup = Join-Path $env:TEMP ("SierraHistoryBridge-Cleanup-" + [guid]::NewGuid().ToString("N") + ".cmd")
    $escaped = $InstallDirectory.Replace('"', '""')

    @"
@echo off
cd /d "%TEMP%"
timeout /t 2 /nobreak >nul 2>&1
rmdir /s /q "$escaped" >nul 2>&1
del /f /q "%~f0" >nul 2>&1
"@ | Set-Content -LiteralPath $cleanup -Encoding ASCII

    Start-Process `
        -FilePath $env:ComSpec `
        -ArgumentList ('/d /c "' + $cleanup + '"') `
        -WindowStyle Hidden | Out-Null
}

function Invoke-Uninstall([string]$InstallScope, [string]$InstallDirectory) {
    Write-Host
    Write-Host "Uninstalling $ProductName..."
    Write-Host "  $InstallDirectory"

    Remove-ExplorerIntegration $InstallScope
    Remove-StartMenuShortcuts $InstallScope
    Remove-UninstallerRegistration $InstallScope

    $removeData = Ask-RemoveUserData

    # Remove legacy setup/runtime material from earlier development builds.
    $legacyApp = Join-Path $UserDataRoot "app"
    $legacyRuntime = Join-Path $UserDataRoot "runtime"
    foreach ($legacy in @($legacyApp, $legacyRuntime)) {
        if (Test-Path -LiteralPath $legacy) {
            Remove-Item -LiteralPath $legacy -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if ($removeData) {
        foreach ($file in @("config.json", "state.json")) {
            $path = Join-Path $UserDataRoot $file
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Write-SetupLog "Uninstall requested: scope=$InstallScope path=$InstallDirectory removeUserData=$removeData"

    # The uninstaller can be running from inside the installation directory.
    # Remove the directory after this PowerShell process exits.
    Schedule-InstallDirectoryRemoval $InstallDirectory

    Write-Host
    Write-Host "$ProductName has been removed from Windows integration." -ForegroundColor Green

    if (-not $removeData) {
        Write-Host "Saved settings were retained at:"
        Write-Host "  $UserDataRoot"
    }
    else {
        # setup.log is left until this process ends; schedule its parent folder
        # for removal only when it contains no user-retained state.
        $dataCleanup = Join-Path $env:TEMP ("SierraHistoryBridge-DataCleanup-" + [guid]::NewGuid().ToString("N") + ".cmd")
        $escapedData = $UserDataRoot.Replace('"', '""')
        @"
@echo off
cd /d "%TEMP%"
timeout /t 3 /nobreak >nul 2>&1
rmdir /s /q "$escapedData" >nul 2>&1
del /f /q "%~f0" >nul 2>&1
"@ | Set-Content -LiteralPath $dataCleanup -Encoding ASCII

        Start-Process `
            -FilePath $env:ComSpec `
            -ArgumentList ('/d /c "' + $dataCleanup + '"') `
            -WindowStyle Hidden | Out-Null
    }

    Write-Host
    Write-Host "Bridge archives, recovery files, and logs were left in their"
    Write-Host "configured storage locations."
}

function Invoke-MaintenanceMenu($Existing) {
    Write-Host "Existing installation found:"
    Write-Host "  Version:  $($Existing.Version)"
    Write-Host "  Location: $($Existing.InstallLocation)"
    Write-Host
    Write-Host "  1. Repair / update"
    Write-Host "  2. Uninstall"
    Write-Host "  3. Cancel"
    Write-Host

    $answer = Read-Host "Choose 1, 2, or 3 [1]"
    if ([string]::IsNullOrWhiteSpace($answer) -or $answer -eq "1") {
        return "Repair"
    }
    if ($answer -eq "2") {
        return "Uninstall"
    }
    return "Cancel"
}

$exitCode = 0

try {
    Show-Header
    Write-SetupLog "Setup launch: mode=$Mode scope=$Scope source=$SourceRoot"

    $resolvedSourceRoot = Resolve-SourceRoot
    $existing = Get-ExistingInstallation

    if ($Mode -eq "Install" -and $existing -and -not $Quiet) {
        $maintenance = Invoke-MaintenanceMenu $existing
        if ($maintenance -eq "Cancel") {
            Write-Host "No changes were made."
            Pause-IfInteractive
            exit 0
        }
        $Mode = $maintenance
        $Scope = $existing.Scope
    }

    if ($Mode -eq "Repair") {
        if (-not $existing) {
            throw "$ProductName is not installed. Run setup in Install mode first."
        }

        if ($Scope -eq "Auto") {
            $Scope = $existing.Scope
        }

        $createStartMenu = Ask-StartMenuPreference $StartMenu $existing.StartMenuShortcuts
        Ensure-Elevation $Mode $Scope $createStartMenu $resolvedSourceRoot | Out-Null
        Invoke-InstallOrRepair $Scope $createStartMenu $resolvedSourceRoot $true
    }
    elseif ($Mode -eq "Uninstall") {
        if (-not $existing) {
            Write-Host "$ProductName is not currently installed."
        }
        else {
            if ($Scope -eq "Auto") {
                $Scope = $existing.Scope
            }

            # Start Menu preference is irrelevant for uninstall, but the
            # elevation helper has one consistent signature.
            Ensure-Elevation $Mode $Scope $false $resolvedSourceRoot | Out-Null
            Invoke-Uninstall $Scope $existing.InstallLocation
        }
    }
    else {
        $Scope = Ask-NewInstallScope
        $createStartMenu = Ask-StartMenuPreference $StartMenu $null

        Ensure-Elevation $Mode $Scope $createStartMenu $resolvedSourceRoot | Out-Null

        $installDirectory = Get-InstallDirectory $Scope
        Invoke-InstallOrRepair $Scope $createStartMenu $resolvedSourceRoot $false
    }
}
catch {
    $exitCode = 1
    Write-SetupLog "ERROR: $($_.Exception.ToString())"
    Write-Host
    Write-Host "SETUP ERROR" -ForegroundColor Red
    Write-Host $_.Exception.Message
    Write-Host
    Write-Host "Setup log:"
    Write-Host "  $SetupLog"
}

Pause-IfInteractive
exit $exitCode

