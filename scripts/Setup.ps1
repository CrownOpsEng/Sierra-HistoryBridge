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
$Publisher = "Sierra History Bridge"
$Version = "0.0.35"

$PowerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$UserDataRoot = Join-Path $env:LOCALAPPDATA $ProductKey
$SetupLog = Join-Path $UserDataRoot "setup.log"

New-Item -ItemType Directory -Path $UserDataRoot -Force | Out-Null

function Write-SetupLog(
    [string]$Message,
    [string]$Level = "INFO") {

    $stamp =
        Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"

    Add-Content `
        -LiteralPath $SetupLog `
        -Value (
            "{0} | {1,-5} | SETUP | {2}" -f
            $stamp,
            $Level.ToUpperInvariant(),
            $Message) `
        -Encoding UTF8
}

function Set-SetupLogDestination(
    [string]$LogFolder) {

    if ([string]::IsNullOrWhiteSpace(
            $LogFolder)) {

        return
    }

    New-Item `
        -ItemType Directory `
        -Path $LogFolder `
        -Force |
        Out-Null

    $newLog =
        Join-Path `
            $LogFolder `
            "setup.log"

    if (-not $SetupLog.Equals(
            $newLog,
            [StringComparison]::OrdinalIgnoreCase)) {

        if (Test-Path `
            -LiteralPath $SetupLog `
            -PathType Leaf) {

            $existing =
                Get-Content `
                    -LiteralPath $SetupLog `
                    -ErrorAction SilentlyContinue

            if ($existing) {
                Add-Content `
                    -LiteralPath $newLog `
                    -Value $existing `
                    -Encoding UTF8
            }

            Remove-Item `
                -LiteralPath $SetupLog `
                -Force `
                -ErrorAction SilentlyContinue
        }

        $script:SetupLog =
            $newLog
    }
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

function Test-SierraPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace(
            $Path)) {

        return $false
    }

    try {
        $resolved =
            [IO.Path]::GetFullPath(
                $Path).TrimEnd('\')
    }
    catch {
        return $false
    }

    if (-not (
        Test-Path `
            -LiteralPath $resolved `
            -PathType Container)) {

        return $false
    }

    foreach ($name in @(
        "SierraChart.exe",
        "SierraChart_64.exe",
        "SierraChart_32.exe"
    )) {
        if (Test-Path `
            -LiteralPath (
                Join-Path `
                    $resolved `
                    $name) `
            -PathType Leaf) {

            return $true
        }
    }

    return $false
}

function Get-DefaultSierraPath {
    $config =
        Read-SetupConfig

    if ($config -and
        $config.sierra_path -and
        (Test-SierraPath `
            ([string]$config.sierra_path))) {

        return [IO.Path]::GetFullPath(
            [string]$config.sierra_path).TrimEnd('\')
    }

    # A remembered Data path is the strongest way to identify the existing
    # Sierra instance when Data still sits beneath that installation.
    if ($config -and
        $config.default_data_folder) {

        try {
            $data =
                [IO.Path]::GetFullPath(
                    [string]$config.default_data_folder).TrimEnd('\')

            $info =
                New-Object IO.DirectoryInfo(
                    $data)

            if ($info.Name.Equals(
                    "Data",
                    [StringComparison]::OrdinalIgnoreCase) -and
                $info.Parent -and
                (Test-SierraPath `
                    $info.Parent.FullName)) {

                return $info.Parent.FullName.TrimEnd('\')
            }
        }
        catch { }
    }

    $runningPaths =
        @()

    try {
        $running =
            @(
                Get-Process `
                    -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.ProcessName -like
                        "SierraChart*"
                }
            )

        foreach ($process in $running) {
            try {
                if ($process.Path) {
                    $candidate =
                        Split-Path `
                            -Parent `
                            $process.Path

                    if ((Test-SierraPath `
                            $candidate) -and
                        $runningPaths -notcontains
                            $candidate) {

                        $runningPaths +=
                            [IO.Path]::GetFullPath(
                                $candidate).TrimEnd('\')
                    }
                }
            }
            catch { }
        }
    }
    catch { }

    if ($runningPaths.Count -eq 1) {
        return $runningPaths[0]
    }

    # Multiple live Sierra installations are deliberately not guessed.
    if ($runningPaths.Count -gt 1) {
        return $null
    }

    $standardPaths =
        @()

    foreach ($candidate in @(
        "C:\SierraChart",
        "C:\SierraChart64",
        "D:\SierraChart",
        "D:\SierraChart64",
        "E:\SierraChart",
        "E:\SierraChart64",
        "F:\SierraChart",
        "F:\SierraChart64"
    )) {
        if ((Test-SierraPath `
                $candidate) -and
            $standardPaths -notcontains
                $candidate) {

            $standardPaths +=
                [IO.Path]::GetFullPath(
                    $candidate).TrimEnd('\')
        }
    }

    if ($standardPaths.Count -eq 1) {
        return $standardPaths[0]
    }

    return $null
}

function Get-DefaultSierraDataFolder(
    [string]$SierraPath) {

    $config =
        Read-SetupConfig

    if ($config -and
        $config.default_data_folder -and
        (Test-Path `
            -LiteralPath ([string]$config.default_data_folder) `
            -PathType Container)) {

        return [IO.Path]::GetFullPath(
            [string]$config.default_data_folder).TrimEnd('\')
    }

    if ($SierraPath) {
        $candidate =
            Join-Path `
                $SierraPath `
                "Data"

        if (Test-Path `
            -LiteralPath $candidate `
            -PathType Container) {

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

function Move-LayoutFileSafely(
    [string]$Source,
    [string]$Destination) {

    if (-not (
        Test-Path `
            -LiteralPath $Source `
            -PathType Leaf)) {

        return
    }

    if (Test-Path `
        -LiteralPath $Destination) {

        throw (
            "Layout relocation destination already exists: " +
            $Destination)
    }

    $parent =
        Split-Path `
            -Parent `
            $Destination

    New-Item `
        -ItemType Directory `
        -Path $parent `
        -Force |
        Out-Null

    Move-Item `
        -LiteralPath $Source `
        -Destination $Destination
}

function Convert-LayoutCompositeBackupName(
    [string]$Name,
    [string]$ProvenanceCode) {

    $normalized =
        $Name.Replace(
            "__",
            "--")

    if ([string]::IsNullOrWhiteSpace(
            $ProvenanceCode)) {

        return $normalized
    }

    $extension =
        $null

    $base =
        $normalized

    if ($base.EndsWith(
            ".gz.meta",
            [StringComparison]::OrdinalIgnoreCase)) {

        $extension =
            ".gz.meta"

        $base =
            $base.Substring(
                0,
                $base.Length -
                    $extension.Length)
    }
    elseif ($base.EndsWith(
            ".gz",
            [StringComparison]::OrdinalIgnoreCase)) {

        $extension =
            ".gz"

        $base =
            $base.Substring(
                0,
                $base.Length -
                    $extension.Length)
    }
    else {
        return $normalized
    }

    $lastSeparator =
        $base.LastIndexOf(
            "--",
            [StringComparison]::Ordinal)

    if ($lastSeparator -le 0) {
        return $normalized
    }

    $prefix =
        $base.Substring(
            0,
            $lastSeparator)

    $target =
        $base.Substring(
            $lastSeparator + 2)

    foreach ($code in @(
        "RT",
        "SC",
        "MX",
        "FR",
        "UN"
    )) {
        $codeSuffix =
            "--" +
            $code

        if ($prefix.EndsWith(
                $codeSuffix,
                [StringComparison]::OrdinalIgnoreCase)) {

            $prefix =
                $prefix.Substring(
                    0,
                    $prefix.Length -
                        $codeSuffix.Length)

            break
        }
    }

    return (
        $prefix +
        "--" +
        $ProvenanceCode +
        "--" +
        $target +
        $extension
    )
}

function Move-LayoutDirectoryContents(
    [string]$Source,
    [string]$Destination,
    [bool]$RenameComposite,
    [string]$ProvenanceCode) {

    if (-not (
        Test-Path `
            -LiteralPath $Source `
            -PathType Container)) {

        return 0
    }

    $moved =
        0

    foreach ($file in @(
        Get-ChildItem `
            -LiteralPath $Source `
            -File `
            -ErrorAction SilentlyContinue)) {

        $name =
            $file.Name

        if ($RenameComposite) {
            $name =
                Convert-LayoutCompositeBackupName `
                    $name `
                    $ProvenanceCode
        }

        Move-LayoutFileSafely `
            $file.FullName `
            (Join-Path `
                $Destination `
                $name)

        $moved++
    }

    foreach ($directory in @(
        Get-ChildItem `
            -LiteralPath $Source `
            -Directory `
            -ErrorAction SilentlyContinue)) {

        $childDestination =
            Join-Path `
                $Destination `
                $directory.Name

        $moved +=
            Move-LayoutDirectoryContents `
                $directory.FullName `
                $childDestination `
                $RenameComposite `
                $ProvenanceCode
    }

    try {
        $remaining =
            @(
                Get-ChildItem `
                    -LiteralPath $Source `
                    -Force `
                    -ErrorAction Stop
            )

        if ($remaining.Count -eq 0) {
            Remove-Item `
                -LiteralPath $Source `
                -Force `
                -ErrorAction Stop
        }
    }
    catch { }

    return $moved
}

function Set-LayoutArchiveProvenance(
    [string]$Directory,
    [string]$Provenance) {

    if (-not (
        Test-Path `
            -LiteralPath $Directory `
            -PathType Container)) {

        return
    }

    foreach ($metadata in @(
        Get-ChildItem `
            -LiteralPath $Directory `
            -File `
            -Filter "*.meta" `
            -ErrorAction SilentlyContinue)) {

        try {
            $lines =
                @(
                    Get-Content `
                        -LiteralPath $metadata.FullName `
                        -ErrorAction Stop
                )

            $found =
                $false

            $updated =
                @()

            foreach ($line in $lines) {
                if ($line.StartsWith(
                        "provenance=",
                        [StringComparison]::OrdinalIgnoreCase)) {

                    if ($Provenance -eq "Unknown") {
                        $updated +=
                            $line
                    }
                    else {
                        $updated +=
                            (
                                "provenance=" +
                                $Provenance
                            )
                    }

                    $found =
                        $true
                }
                else {
                    $updated +=
                        $line
                }
            }

            if (-not $found) {
                $updated +=
                    (
                        "provenance=" +
                        $Provenance
                    )
            }

            $updated |
                Set-Content `
                    -LiteralPath $metadata.FullName `
                    -Encoding UTF8
        }
        catch {
            Write-Host (
                "Metadata provenance warning: " +
                $metadata.FullName +
                " | " +
                $_.Exception.Message) `
                -ForegroundColor Yellow
        }
    }
}

function Read-SetupArchiveMeta(
    [string]$ArchivePath) {

    $metadataPath =
        $ArchivePath +
        ".meta"

    if (-not (
        Test-Path `
            -LiteralPath $metadataPath `
            -PathType Leaf)) {

        return $null
    }

    $values =
        @{}

    foreach ($line in @(
        Get-Content `
            -LiteralPath $metadataPath `
            -ErrorAction Stop)) {

        $separator =
            $line.IndexOf("=")

        if ($separator -le 0) {
            continue
        }

        $values[
            $line.Substring(
                0,
                $separator)
        ] =
            $line.Substring(
                $separator + 1)
    }

    return $values
}

function Remove-SetupHeaderOnlyArchives(
    [string]$StorageFolder) {

    $removed =
        0

    foreach ($category in @(
        "Archive",
        "Baselines",
        "Rollbacks",
        "RestoreConflicts"
    )) {
        $directory =
            Join-Path `
                $StorageFolder `
                $category

        if (-not (
            Test-Path `
                -LiteralPath $directory `
                -PathType Container)) {

            continue
        }

        foreach ($archive in @(
            Get-ChildItem `
                -LiteralPath $directory `
                -File `
                -Filter "*.gz" `
                -ErrorAction SilentlyContinue
        )) {
            try {
                $presence =
                    [SierraHistoryBridge.ScidBridge]::GetGzipMarketDataPresence(
                        $archive.FullName)

                if ($presence -ne 0) {
                    continue
                }

                Remove-Item `
                    -LiteralPath $archive.FullName `
                    -Force `
                    -ErrorAction Stop

                Remove-Item `
                    -LiteralPath ($archive.FullName + ".meta") `
                    -Force `
                    -ErrorAction SilentlyContinue

                $removed++

                Write-SetupLog (
                    "Header-only archive removed: " +
                    $archive.FullName)
            }
            catch {
                Write-SetupLog (
                    "Header-only archive check left file untouched: " +
                    $archive.FullName +
                    " | " +
                    $_.Exception.Message) `
                    "WARN"
            }
        }

        try {
            $remaining =
                @(
                    Get-ChildItem `
                        -LiteralPath $directory `
                        -Force `
                        -ErrorAction Stop
                )

            if ($remaining.Count -eq 0) {
                Remove-Item `
                    -LiteralPath $directory `
                    -Force `
                    -ErrorAction Stop
            }
        }
        catch { }
    }

    if ($removed -gt 0) {
        Write-Host (
            "  Removed {0} header-only bridge archive(s)." -f
            $removed) `
            -ForegroundColor Yellow
    }

    return $removed
}

function Remove-SetupHeaderOnlyTempFiles(
    [string]$TempFolder) {

    if (-not (
        Test-Path `
            -LiteralPath $TempFolder `
            -PathType Container)) {

        return 0
    }

    $removed =
        0

    foreach ($file in @(
        Get-ChildItem `
            -LiteralPath $TempFolder `
            -File `
            -Filter "*.bak" `
            -ErrorAction SilentlyContinue
    )) {
        $records =
            -1L

        try {
            $records =
                [long](
                    [SierraHistoryBridge.ScidBridge]::GetMeta(
                        $file.FullName).Records)
        }
        catch {
            try {
                $records =
                    [long](
                        [SierraHistoryBridge.DailyBridge]::GetMeta(
                            $file.FullName).Records)
            }
            catch {
                $records =
                    -1L
            }
        }

        if ($records -eq 0) {
            try {
                Remove-Item `
                    -LiteralPath $file.FullName `
                    -Force `
                    -ErrorAction Stop

                $removed++

                Write-SetupLog (
                    "Header-only temp file removed: " +
                    $file.FullName)
            }
            catch {
                Write-SetupLog (
                    "Header-only temp file could not be removed: " +
                    $file.FullName +
                    " | " +
                    $_.Exception.Message) `
                    "WARN"
            }
        }
    }

    try {
        $remaining =
            @(
                Get-ChildItem `
                    -LiteralPath $TempFolder `
                    -Force `
                    -ErrorAction Stop
            )

        if ($remaining.Count -eq 0) {
            Remove-Item `
                -LiteralPath $TempFolder `
                -Force `
                -ErrorAction Stop
        }
    }
    catch { }

    return $removed
}

function Get-SetupBackupTargetName(
    [string]$ArchivePath) {

    $rithmicPattern =
        [regex]'^(?<root>[A-Za-z0-9_]+)(?<month>[FGHJKMNQUVXZ])(?<year>\d)\.(?<exchange>[A-Za-z0-9_]+)\.(?<extension>scid|dly)$'

    $targetSuffixPattern =
        [regex]'(?:--|__|-)(?<target>[A-Za-z0-9_]+[FGHJKMNQUVXZ]\d\.[A-Za-z0-9_]+\.(?:scid|dly))$'

    $name =
        [IO.Path]::GetFileName(
            $ArchivePath)

    if ($name.EndsWith(
            ".gz",
            [StringComparison]::OrdinalIgnoreCase)) {

        $name =
            $name.Substring(
                0,
                $name.Length - 3)
    }

    $suffixMatch =
        $targetSuffixPattern.Match(
            $name)

    if ($suffixMatch.Success) {
        $target =
            $suffixMatch.Groups[
                "target"].Value

        if ($rithmicPattern.IsMatch(
                $target)) {

            return $target
        }
    }

    if ($rithmicPattern.IsMatch(
            $name)) {

        return $name
    }

    $meta =
        Read-SetupArchiveMeta `
            $ArchivePath

    if ($meta -and
        $meta.ContainsKey(
            "original_name")) {

        $candidate =
            [IO.Path]::GetFileName(
                [string]$meta["original_name"])

        if ($candidate -eq
                [string]$meta["original_name"]) {

            $metadataSuffix =
                $targetSuffixPattern.Match(
                    $candidate)

            if ($metadataSuffix.Success) {
                $metadataTarget =
                    $metadataSuffix.Groups[
                        "target"].Value

                if ($rithmicPattern.IsMatch(
                        $metadataTarget)) {

                    return $metadataTarget
                }
            }

            if ($rithmicPattern.IsMatch(
                    $candidate)) {

                return $candidate
            }
        }
    }

    return $null
}

function Get-SetupProvenanceCode(
    [string]$Provenance) {

    switch ($Provenance.Trim().ToLowerInvariant()) {
        "rithmic" { return "RT" }
        "scdata" { return "SC" }
        "hybrid" { return "MX" }
        "foreign" { return "FR" }
        default { return "UN" }
    }
}

function Get-SetupProvenanceFromContent(
    [string]$ContentClass) {

    switch ($ContentClass) {
        "ForeignLike" { return "Foreign" }

        # SCDataLike cannot prove purity by itself; a Rithmic live suffix can
        # contain zero-Open records. Mixed requires a clean segment cutoff
        # before Setup labels it Hybrid.
        default { return "Unknown" }
    }
}

function Convert-SetupScDateTimeToUtc(
    [long]$Value) {

    if ($Value -le 0) {
        return $null
    }

    try {
        $epoch =
            [datetime]::SpecifyKind(
                [datetime]"1899-12-30",
                [DateTimeKind]::Utc)

        return $epoch.AddTicks(
            ($Value * 10L))
    }
    catch {
        return $null
    }
}


function Set-SetupArchiveOriginalName(
    [string]$ArchivePath,
    [string]$TargetName) {

    if ([string]::IsNullOrWhiteSpace(
            $TargetName)) {

        return
    }

    $metadataPath =
        $ArchivePath +
        ".meta"

    if (-not (
        Test-Path `
            -LiteralPath $metadataPath `
            -PathType Leaf)) {

        return
    }

    $values =
        [ordered]@{}

    foreach ($line in @(
        Get-Content `
            -LiteralPath $metadataPath `
            -ErrorAction Stop)) {

        $separator =
            $line.IndexOf("=")

        if ($separator -le 0) {
            continue
        }

        $key =
            $line.Substring(
                0,
                $separator)

        $values[$key] =
            $line.Substring(
                $separator + 1)
    }

    $values["original_name"] =
        $TargetName

    $lines =
        @()

    foreach ($entry in $values.GetEnumerator()) {
        $lines +=
            (
                [string]$entry.Key +
                "=" +
                [string]$entry.Value
            )
    }

    $lines |
        Set-Content `
            -LiteralPath $metadataPath `
            -Encoding UTF8
}

function Set-SetupArchiveEvidence(
    [string]$ArchivePath,
    [string]$Provenance,
    $Inspection,
    [long]$CutoverDateTime = 0) {

    $metadataPath =
        $ArchivePath +
        ".meta"

    if (-not (
        Test-Path `
            -LiteralPath $metadataPath `
            -PathType Leaf)) {

        return
    }

    $values =
        [ordered]@{}

    foreach ($line in @(
        Get-Content `
            -LiteralPath $metadataPath `
            -ErrorAction Stop)) {

        $separator =
            $line.IndexOf("=")

        if ($separator -le 0) {
            continue
        }

        $key =
            $line.Substring(
                0,
                $separator)

        $values[$key] =
            $line.Substring(
                $separator + 1)
    }

    $values["provenance"] =
        $Provenance

    if ($CutoverDateTime -gt 0) {
        $values["cutover_datetime"] =
            [string]$CutoverDateTime

        $cutover =
            Convert-SetupScDateTimeToUtc `
                $CutoverDateTime

        if ($cutover) {
            $values["cutover_utc"] =
                $cutover.ToString(
                    "yyyy-MM-dd HH:mm:ss 'UTC'",
                    [Globalization.CultureInfo]::InvariantCulture)
        }
    }
    else {
        [void]$values.Remove(
            "cutover_datetime")

        [void]$values.Remove(
            "cutover_utc")
    }

    if ($Inspection) {
        $archiveInfo =
            Get-Item `
                -LiteralPath $ArchivePath `
                -ErrorAction Stop

        $values["verified_archive_bytes"] =
            [string][long]$archiveInfo.Length

        $values["verified_archive_write_ticks"] =
            [string][long]$archiveInfo.LastWriteTimeUtc.Ticks

        $values["verified_content_sha256"] =
            [string]$Inspection.Sha256

        $values["content_class"] =
            [string]$Inspection.ContentClass

        $values["special_control_open_records"] =
            [string][long]$Inspection.SpecialControlOpenRecords

        $values["regular_open_records"] =
            [string][long]$Inspection.RegularOpenRecords

        $values["zero_open_records"] =
            [string][long]$Inspection.ZeroOpenRecords

        $values["other_open_records"] =
            [string][long]$Inspection.OtherOpenRecords

        if ([long]$Inspection.SegmentCutoverDateTime -gt 0) {
            $values["morphology_cutover_datetime"] =
                [string][long]$Inspection.SegmentCutoverDateTime
        }
    }

    $lines =
        @()

    foreach ($entry in $values.GetEnumerator()) {
        $lines +=
            (
                [string]$entry.Key +
                "=" +
                [string]$entry.Value
            )
    }

    $lines |
        Set-Content `
            -LiteralPath $metadataPath `
            -Encoding UTF8
}

function Rename-SetupBackupForProvenance(
    [string]$ArchivePath,
    [string]$TargetName,
    [string]$Provenance,
    [long]$CutoverDateTime = 0) {

    $code =
        Get-SetupProvenanceCode `
            $Provenance

    $name =
        [IO.Path]::GetFileName(
            $ArchivePath)

    $directory =
        Split-Path `
            -Parent `
            $ArchivePath

    $stem =
        if ($name.EndsWith(
                ".gz",
                [StringComparison]::OrdinalIgnoreCase)) {

            $name.Substring(
                0,
                $name.Length - 3)
        }
        else {
            $name
        }

    if (-not $stem.EndsWith(
            $TargetName,
            [StringComparison]::OrdinalIgnoreCase)) {

        return $ArchivePath
    }

    $prefix =
        $stem.Substring(
            0,
            $stem.Length -
                $TargetName.Length).TrimEnd(
                    [char[]]"-_")

    if ([string]::IsNullOrWhiteSpace(
            $prefix)) {

        return $ArchivePath
    }

    $codeMatch =
        [regex]::Match(
            $prefix,
            '--(?:RT|SC|FR|UN|MX(?:-\d{8}T\d{6}Z)?)$',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase)

    if ($codeMatch.Success) {
        $prefix =
            $prefix.Substring(
                0,
                $codeMatch.Index)
    }

    if ([string]::IsNullOrWhiteSpace(
            $prefix)) {

        return $ArchivePath
    }

    $newPath =
        Join-Path `
            $directory `
            (
                $prefix +
                "--" +
                $code +
                "--" +
                $TargetName +
                ".gz"
            )

    if ($newPath.Equals(
            $ArchivePath,
            [StringComparison]::OrdinalIgnoreCase)) {

        Set-SetupArchiveOriginalName `
            $ArchivePath `
            $TargetName

        return $ArchivePath
    }

    if (Test-Path `
        -LiteralPath $newPath) {

        Write-Host (
            "Backup name warning: destination already exists; leaving current name: " +
            $ArchivePath) `
            -ForegroundColor Yellow

        Set-SetupArchiveOriginalName `
            $ArchivePath `
            $TargetName

        return $ArchivePath
    }

    Move-Item `
        -LiteralPath $ArchivePath `
        -Destination $newPath

    $oldMeta =
        $ArchivePath +
        ".meta"

    $newMeta =
        $newPath +
        ".meta"

    if (Test-Path `
        -LiteralPath $oldMeta `
        -PathType Leaf) {

        Move-Item `
            -LiteralPath $oldMeta `
            -Destination $newMeta
    }

    Set-SetupArchiveOriginalName `
        $newPath `
        $TargetName

    return $newPath
}

function Normalize-SetupProvenance(
    [string]$Value) {

    if ([string]::IsNullOrWhiteSpace(
            $Value)) {

        return "Unknown"
    }

    switch ($Value.Trim().ToLowerInvariant()) {
        "rithmic" { return "Rithmic" }
        "scdata" { return "SCData" }
        "hybrid" { return "Hybrid" }
        "foreign" { return "Foreign" }
        default { return "Unknown" }
    }
}

function Find-SetupScDataSource(
    [string]$DataFolder,
    [string]$TargetName) {

    $targetPattern =
        [regex]'^(?<root>.+?)(?<month>[FGHJKMNQUVXZ])(?<year>\d)\.(?<exchange>[A-Za-z0-9_]+)\.scid$'

    $sourcePattern =
        [regex]'^(?<root>.+?)(?<month>[FGHJKMNQUVXZ])(?<year>\d{2})-(?<exchange>[A-Za-z0-9_]+)\.scid$'

    $target =
        $targetPattern.Match(
            $TargetName)

    if (-not $target.Success) {
        return $null
    }

    $matches =
        @(
            Get-ChildItem `
                -LiteralPath $DataFolder `
                -File `
                -Filter "*.scid" `
                -ErrorAction SilentlyContinue |
            Where-Object {
                $source =
                    $sourcePattern.Match(
                        $_.Name)

                $source.Success -and
                $source.Groups["root"].Value.Equals(
                    $target.Groups["root"].Value,
                    [StringComparison]::OrdinalIgnoreCase) -and
                $source.Groups["month"].Value.Equals(
                    $target.Groups["month"].Value,
                    [StringComparison]::OrdinalIgnoreCase) -and
                $source.Groups["year"].Value.EndsWith(
                    $target.Groups["year"].Value,
                    [StringComparison]::OrdinalIgnoreCase) -and
                $source.Groups["exchange"].Value.Equals(
                    $target.Groups["exchange"].Value,
                    [StringComparison]::OrdinalIgnoreCase)
            }
        )

    if ($matches.Count -eq 1) {
        return $matches[0].FullName
    }

    return $null
}

function Get-SetupProvenanceScale(
    [string]$DataFolder,
    [string]$TargetName,
    [string]$SourcePath,
    $Config) {

    $targetPattern =
        [regex]'^(?<root>.+?)[FGHJKMNQUVXZ]\d\.(?<exchange>[A-Za-z0-9_]+)\.scid$'

    $match =
        $targetPattern.Match(
            $TargetName)

    if ($match.Success -and
        $Config -and
        $Config.proven_scales) {

        $group =
            "{0}|{1}" -f
            $match.Groups["root"].Value.ToUpperInvariant(),
            $match.Groups["exchange"].Value.ToUpperInvariant()

        if ($Config.proven_scales.PSObject.Properties[
                $group]) {

            try {
                return [double]$Config.proven_scales.$group
            }
            catch { }
        }
    }

    $currentTarget =
        Join-Path `
            $DataFolder `
            $TargetName

    if (Test-Path `
        -LiteralPath $currentTarget `
        -PathType Leaf) {

        try {
            $inference =
                [SierraHistoryBridge.ScidBridge]::InferScale(
                    $SourcePath,
                    $currentTarget)

            return [double]$inference.Factor
        }
        catch { }
    }

    return 0.0
}

function Test-SetupArchiveInspectionCache(
    [System.IO.FileInfo]$Archive,
    $Meta) {

    if (-not $Meta -or
        -not $Meta.ContainsKey(
            "verified_archive_bytes") -or
        -not $Meta.ContainsKey(
            "verified_archive_write_ticks") -or
        -not $Meta.ContainsKey(
            "verified_content_sha256") -or
        -not $Meta.ContainsKey(
            "content_class")) {

        return $false
    }

    try {
        return (
            [long]$Meta["verified_archive_bytes"] -eq
                [long]$Archive.Length -and
            [long]$Meta["verified_archive_write_ticks"] -eq
                [long]$Archive.LastWriteTimeUtc.Ticks -and
            [string]$Meta["verified_content_sha256"] -ieq
                [string]$Meta["sha256"]
        )
    }
    catch {
        return $false
    }
}

function Get-SetupSourceRelationshipIdentity(
    [string]$SourcePath,
    [double]$Scale) {

    $file =
        Get-Item `
            -LiteralPath $SourcePath `
            -ErrorAction Stop

    return [pscustomobject]@{
        Bytes =
            [long]$file.Length
        WriteTicks =
            [long]$file.LastWriteTimeUtc.Ticks
        Signature =
            [SierraHistoryBridge.ScidBridge]::GetQuickSignature(
                $SourcePath)
        Scale =
            $Scale.ToString(
                "R",
                [Globalization.CultureInfo]::InvariantCulture)
    }
}

function Get-SetupCachedSourceRelationship(
    $Meta,
    [string]$SourcePath,
    [double]$Scale) {

    if (-not $Meta -or
        -not $Meta.ContainsKey("relationship_source_path") -or
        -not $Meta.ContainsKey("relationship_source_bytes") -or
        -not $Meta.ContainsKey("relationship_source_write_ticks") -or
        -not $Meta.ContainsKey("relationship_source_signature") -or
        -not $Meta.ContainsKey("relationship_scale") -or
        -not $Meta.ContainsKey("relationship_result")) {

        return $null
    }

    try {
        $identity =
            Get-SetupSourceRelationshipIdentity `
                $SourcePath `
                $Scale

        $savedPath =
            [IO.Path]::GetFullPath(
                [string]$Meta["relationship_source_path"]).TrimEnd('\')

        $currentPath =
            [IO.Path]::GetFullPath(
                $SourcePath).TrimEnd('\')

        if (-not $savedPath.Equals(
                $currentPath,
                [StringComparison]::OrdinalIgnoreCase) -or
            [long]$Meta["relationship_source_bytes"] -ne
                [long]$identity.Bytes -or
            [long]$Meta["relationship_source_write_ticks"] -ne
                [long]$identity.WriteTicks -or
            [string]$Meta["relationship_source_signature"] -ne
                [string]$identity.Signature -or
            [string]$Meta["relationship_scale"] -ne
                [string]$identity.Scale) {

            return $null
        }

        return [pscustomobject]@{
            Relationship =
                [string]$Meta["relationship_result"]
            CutoverDateTime =
                if ($Meta.ContainsKey(
                    "relationship_cutover_datetime")) {
                    [long]$Meta["relationship_cutover_datetime"]
                }
                else {
                    0L
                }
        }
    }
    catch {
        return $null
    }
}

function Set-SetupSourceRelationshipEvidence(
    [string]$ArchivePath,
    [string]$SourcePath,
    [double]$Scale,
    $Relationship) {

    $metadataPath =
        $ArchivePath +
        ".meta"

    if (-not (
        Test-Path `
            -LiteralPath $metadataPath `
            -PathType Leaf)) {

        return
    }

    $identity =
        Get-SetupSourceRelationshipIdentity `
            $SourcePath `
            $Scale

    $values =
        [ordered]@{}

    foreach ($line in @(
        Get-Content `
            -LiteralPath $metadataPath `
            -ErrorAction Stop)) {

        $separator =
            $line.IndexOf("=")

        if ($separator -le 0) {
            continue
        }

        $values[
            $line.Substring(
                0,
                $separator)
        ] =
            $line.Substring(
                $separator + 1)
    }

    $values["relationship_source_path"] =
        [IO.Path]::GetFullPath(
            $SourcePath).TrimEnd('\')

    $values["relationship_source_bytes"] =
        [string][long]$identity.Bytes

    $values["relationship_source_write_ticks"] =
        [string][long]$identity.WriteTicks

    $values["relationship_source_signature"] =
        [string]$identity.Signature

    $values["relationship_scale"] =
        [string]$identity.Scale

    $values["relationship_result"] =
        [string]$Relationship.Relationship

    $values["relationship_cutover_datetime"] =
        [string][long]$Relationship.CutoverDateTime

    $lines =
        @()

    foreach ($entry in $values.GetEnumerator()) {
        $lines +=
            (
                [string]$entry.Key +
                "=" +
                [string]$entry.Value
            )
    }

    $lines |
        Set-Content `
            -LiteralPath $metadataPath `
            -Encoding UTF8
}

function Move-SetupBaselineToRollbacks(
    [string]$ArchivePath,
    [string]$RollbackDirectory,
    [string]$TargetName,
    [string]$Provenance,
    [long]$CutoverDateTime,
    $Inspection) {

    New-Item `
        -ItemType Directory `
        -Path $RollbackDirectory `
        -Force |
        Out-Null

    $name =
        [IO.Path]::GetFileName(
            $ArchivePath)

    $destination =
        Join-Path `
            $RollbackDirectory `
            $name

    if (Test-Path `
        -LiteralPath $destination) {

        $stamp =
            (Get-Date).ToString(
                "yyyyMMdd-HHmmss-fff")

        $destination =
            Join-Path `
                $RollbackDirectory `
                (
                    "baseline-review-" +
                    $stamp +
                    "-" +
                    [guid]::NewGuid().ToString("N").Substring(0, 8) +
                    "--UN--" +
                    $TargetName +
                    ".gz"
                )
    }

    Move-Item `
        -LiteralPath $ArchivePath `
        -Destination $destination

    $oldMeta =
        $ArchivePath +
        ".meta"

    $newMeta =
        $destination +
        ".meta"

    if (Test-Path `
        -LiteralPath $oldMeta `
        -PathType Leaf) {

        Move-Item `
            -LiteralPath $oldMeta `
            -Destination $newMeta
    }

    Set-SetupArchiveEvidence `
        $destination `
        $Provenance `
        $Inspection `
        $CutoverDateTime

    return Rename-SetupBackupForProvenance `
        $destination `
        $TargetName `
        $Provenance `
        $CutoverDateTime
}

function Move-SetupUnidentifiedBaselineToRollbacks(
    [string]$ArchivePath,
    [string]$RollbackDirectory) {

    if (-not (
        Test-Path `
            -LiteralPath $ArchivePath `
            -PathType Leaf)) {

        return $null
    }

    New-Item `
        -ItemType Directory `
        -Path $RollbackDirectory `
        -Force |
        Out-Null

    $stamp =
        (Get-Date).ToString(
            "yyyyMMdd-HHmmss-fff")

    $originalName =
        [IO.Path]::GetFileName(
            $ArchivePath)

    if ($originalName.EndsWith(
            ".gz",
            [StringComparison]::OrdinalIgnoreCase)) {

        $originalName =
            $originalName.Substring(
                0,
                $originalName.Length - 3)
    }

    $destination =
        Join-Path `
            $RollbackDirectory `
            (
                "baseline-review-" +
                $stamp +
                "-" +
                [guid]::NewGuid().ToString("N").Substring(0, 8) +
                "--UN--unidentified.gz"
            )

    Move-Item `
        -LiteralPath $ArchivePath `
        -Destination $destination

    $oldMeta =
        $ArchivePath +
        ".meta"

    $newMeta =
        $destination +
        ".meta"

    if (Test-Path `
        -LiteralPath $oldMeta `
        -PathType Leaf) {

        Move-Item `
            -LiteralPath $oldMeta `
            -Destination $newMeta
    }

    return $destination
}

function Normalize-RithmicBackupProvenance(
    [string]$StorageFolder,
    [string]$DataFolder,
    $Config) {

    $baselineDirectory =
        Join-Path `
            $StorageFolder `
            "Baselines"

    $rollbackDirectory =
        Join-Path `
            $StorageFolder `
            "Rollbacks"

    $authenticated =
        @{}

    $baselineArchives =
        @(
            Get-ChildItem `
                -LiteralPath $baselineDirectory `
                -File `
                -Filter "*.gz" `
                -ErrorAction SilentlyContinue
        )

    if ($baselineArchives.Count -gt 0) {
        Write-Host
        Write-Host (
            "Verifying {0} Rithmic baseline backup(s)..." -f
            $baselineArchives.Count)
    }

    foreach ($archive in $baselineArchives) {
        $meta =
            $null

        $target =
            $null

        $inspection =
            $null

        $provenance =
            "Unknown"

        $cutover =
            0L

        try {
            $meta =
                Read-SetupArchiveMeta `
                    $archive.FullName

            $target =
                Get-SetupBackupTargetName `
                    $archive.FullName

            if ($target) {
                Set-SetupArchiveOriginalName `
                    $archive.FullName `
                    $target

                $meta =
                    Read-SetupArchiveMeta `
                        $archive.FullName
            }

            if (-not $meta -or
                -not $target -or
                -not $meta.ContainsKey("sha256") -or
                -not $meta.ContainsKey("original_bytes")) {

                throw "Baseline metadata is incomplete."
            }

            $existing =
                Normalize-SetupProvenance `
                    ([string]$meta["provenance"])

            $inspection =
                $null

            $cacheValid =
                Test-SetupArchiveInspectionCache `
                    $archive `
                    $meta

            if (-not $cacheValid) {
                if (-not $target.EndsWith(
                        ".scid",
                        [StringComparison]::OrdinalIgnoreCase)) {

                    throw "Only verified SCID content can be authenticated as a Rithmic baseline."
                }

                $inspection =
                    [SierraHistoryBridge.ScidBridge]::InspectGzipScidContent(
                        $archive.FullName)

                if ([long]$inspection.Length -ne
                        [long]$meta["original_bytes"] -or
                    [string]$inspection.Sha256 -ine
                        [string]$meta["sha256"]) {

                    throw "Baseline content does not match its verified metadata."
                }
            }

            $contentClass =
                if ($inspection) {
                    [string]$inspection.ContentClass
                }
                else {
                    [string]$meta["content_class"]
                }

            $special =
                if ($inspection) {
                    [long]$inspection.SpecialControlOpenRecords
                }
                elseif ($meta.ContainsKey(
                    "special_control_open_records")) {
                    [long]$meta["special_control_open_records"]
                }
                else {
                    0L
                }

            $regular =
                if ($inspection) {
                    [long]$inspection.RegularOpenRecords
                }
                elseif ($meta.ContainsKey(
                    "regular_open_records")) {
                    [long]$meta["regular_open_records"]
                }
                else {
                    0L
                }

            $other =
                if ($inspection) {
                    [long]$inspection.OtherOpenRecords
                }
                elseif ($meta.ContainsKey(
                    "other_open_records")) {
                    [long]$meta["other_open_records"]
                }
                else {
                    0L
                }

            $nativeShape =
                $contentClass -eq "ForeignLike" -and
                $special -eq 0 -and
                $regular -gt 0 -and
                $other -eq 0

            if ($nativeShape -and
                $existing -notin @(
                    "SCData",
                    "Hybrid",
                    "Foreign")) {

                $provenance =
                    "Rithmic"

                Set-SetupArchiveEvidence `
                    $archive.FullName `
                    $provenance `
                    $inspection `
                    0

                $renamed =
                    Rename-SetupBackupForProvenance `
                        $archive.FullName `
                        $target `
                        $provenance `
                        0

                $meta =
                    Read-SetupArchiveMeta `
                        $renamed

                $identity =
                    (
                        $target.ToUpperInvariant() +
                        "|" +
                        [string]$meta["original_bytes"] +
                        "|" +
                        ([string]$meta["sha256"]).ToUpperInvariant()
                    )

                $authenticated[$identity] =
                    $true

                Write-Host (
                    "  RT {0}" -f
                    ([IO.Path]::GetFileName(
                        $renamed)))

                continue
            }

            # Baselines is an invariant, not a miscellaneous backup folder.
            # Anything that cannot be authenticated as native Rithmic is
            # retained but moved to Rollbacks with conservative identity.
            $cutover =
                0L

            if ($existing -eq "SCData") {
                $provenance = "SCData"
            }
            elseif ($existing -eq "Hybrid") {
                $provenance = "Hybrid"

                if ($meta.ContainsKey(
                    "cutover_datetime")) {
                    $cutover =
                        [long]$meta["cutover_datetime"]
                }
            }
            elseif ($contentClass -eq "Mixed" -and
                $inspection -and
                [long]$inspection.SegmentCutoverDateTime -gt 0) {

                $provenance = "Hybrid"
                $cutover =
                    [long]$inspection.SegmentCutoverDateTime
            }
            elseif ($contentClass -eq "ForeignLike") {
                $provenance = "Foreign"
            }
            else {
                $provenance = "Unknown"
            }

            $moved =
                Move-SetupBaselineToRollbacks `
                    $archive.FullName `
                    $rollbackDirectory `
                    $target `
                    $provenance `
                    $cutover `
                    $inspection

            Write-Host (
                "  moved from Baselines: {0} | {1}" -f
                ([IO.Path]::GetFileName(
                    $moved)),
                (Get-SetupProvenanceCode `
                    $provenance)) `
                -ForegroundColor Yellow
        }
        catch {
            $errorText =
                $_.Exception.Message

            try {
                $preserved =
                    if (-not [string]::IsNullOrWhiteSpace(
                            $target)) {

                        Move-SetupBaselineToRollbacks `
                            $archive.FullName `
                            $rollbackDirectory `
                            $target `
                            "Unknown" `
                            0 `
                            $inspection
                    }
                    else {
                        Move-SetupUnidentifiedBaselineToRollbacks `
                            $archive.FullName `
                            $rollbackDirectory
                    }

                Write-Host (
                    "Baseline rejected and preserved in Rollbacks: " +
                    $preserved +
                    " | " +
                    $errorText) `
                    -ForegroundColor Yellow
            }
            catch {
                throw (
                    "A file in Baselines could not be authenticated and could " +
                    "not be moved safely to Rollbacks. Repair stopped to preserve " +
                    "the Baselines invariant. File: " +
                    $archive.FullName +
                    " | validation error: " +
                    $errorText +
                    " | relocation error: " +
                    $_.Exception.Message)
            }
        }
    }

    $rollbackArchives =
        @(
            Get-ChildItem `
                -LiteralPath $rollbackDirectory `
                -File `
                -Filter "*.gz" `
                -ErrorAction SilentlyContinue
        )

    if ($rollbackArchives.Count -gt 0) {
        Write-Host
        Write-Host (
            "Classifying {0} Rithmic rollback backup(s)..." -f
            $rollbackArchives.Count)
    }

    $rollbackIndex = 0

    foreach ($archive in $rollbackArchives) {
        $rollbackIndex++

        try {
            $meta =
                Read-SetupArchiveMeta `
                    $archive.FullName

            $target =
                Get-SetupBackupTargetName `
                    $archive.FullName

            if ($target) {
                Set-SetupArchiveOriginalName `
                    $archive.FullName `
                    $target

                $meta =
                    Read-SetupArchiveMeta `
                        $archive.FullName
            }

            if (-not $meta -or
                -not $target -or
                -not $meta.ContainsKey("sha256") -or
                -not $meta.ContainsKey("original_bytes")) {

                Write-Host (
                    "  [{0}/{1}] UN {2} | incomplete metadata" -f
                    $rollbackIndex,
                    $rollbackArchives.Count,
                    $archive.Name) `
                    -ForegroundColor Yellow

                continue
            }

            $identity =
                (
                    $target.ToUpperInvariant() +
                    "|" +
                    [string]$meta["original_bytes"] +
                    "|" +
                    ([string]$meta["sha256"]).ToUpperInvariant()
                )

            $existing =
                Normalize-SetupProvenance `
                    ([string]$meta["provenance"])

            $provenance =
                if ($authenticated.ContainsKey(
                        $identity)) {

                    "Rithmic"
                }
                else {
                    $existing
                }

            $cutover =
                if ($meta.ContainsKey(
                    "cutover_datetime")) {
                    [long]$meta["cutover_datetime"]
                }
                else {
                    0L
                }

            $inspection =
                $null

            $cacheValid =
                Test-SetupArchiveInspectionCache `
                    $archive `
                    $meta

            # Known bridge evidence can be reused only while the compressed
            # archive itself is unchanged. Unknown or changed archives are
            # inspected again.
            if (-not $cacheValid) {

                if ($target.EndsWith(
                        ".scid",
                        [StringComparison]::OrdinalIgnoreCase)) {

                    $inspection =
                        [SierraHistoryBridge.ScidBridge]::InspectGzipScidContent(
                            $archive.FullName)

                    if ([long]$inspection.Length -ne
                            [long]$meta["original_bytes"] -or
                        [string]$inspection.Sha256 -ine
                            [string]$meta["sha256"]) {

                        throw "Rollback content does not match its verified metadata."
                    }
                }
            }

            if (-not $authenticated.ContainsKey(
                    $identity)) {

                # Existing explicit evidence survives only when content does
                # not contradict it. Provider identity is never inferred from
                # morphology alone.
                if ($provenance -eq "Rithmic") {
                    if ($inspection -and
                        [string]$inspection.ContentClass -ne "ForeignLike") {

                        $provenance =
                            "Unknown"
                    }
                }
                elseif ($provenance -eq "SCData") {
                    if ($inspection -and
                        [string]$inspection.ContentClass -eq "ForeignLike") {

                        $provenance =
                            "Unknown"
                    }
                }
                elseif ($provenance -eq "Hybrid") {
                    if ($cutover -le 0 -and
                        $inspection -and
                        [string]$inspection.ContentClass -eq "Mixed" -and
                        [long]$inspection.SegmentCutoverDateTime -gt 0) {

                        $cutover =
                            [long]$inspection.SegmentCutoverDateTime
                    }
                }
            }

            # If identity is still unknown, compare the compressed data
            # directly against the matching SC Data source. This is exact
            # record relationship testing, not filename/morphology guessing.
            if ($provenance -eq "Unknown" -and
                $target.EndsWith(
                    ".scid",
                    [StringComparison]::OrdinalIgnoreCase)) {

                $source =
                    Find-SetupScDataSource `
                        $DataFolder `
                        $target

                if ($source) {
                    $scale =
                        Get-SetupProvenanceScale `
                            $DataFolder `
                            $target `
                            $source `
                            $Config

                    if ($scale -gt 0) {
                        $relationship =
                            Get-SetupCachedSourceRelationship `
                                $meta `
                                $source `
                                $scale

                        if (-not $relationship) {
                            $relationship =
                                [SierraHistoryBridge.ScidBridge]::InspectGzipScidRelationshipToSource(
                                    $source,
                                    $archive.FullName,
                                    [long]$meta["original_bytes"],
                                    $scale)

                            Set-SetupSourceRelationshipEvidence `
                                $archive.FullName `
                                $source `
                                $scale `
                                $relationship
                        }

                        switch ([string]$relationship.Relationship) {
                            "SCData" {
                                $provenance =
                                    "SCData"
                            }

                            "Mixed" {
                                $provenance =
                                    "Hybrid"

                                $cutover =
                                    [long]$relationship.CutoverDateTime
                            }

                            "Foreign" {
                                $provenance =
                                    "Foreign"
                            }
                        }
                    }
                }
            }

            if ($provenance -eq "Unknown" -and
                $inspection) {

                if ([string]$inspection.ContentClass -eq "Mixed" -and
                    [long]$inspection.SegmentCutoverDateTime -gt 0) {

                    $provenance =
                        "Hybrid"

                    $cutover =
                        [long]$inspection.SegmentCutoverDateTime
                }
                elseif ([string]$inspection.ContentClass -eq "ForeignLike") {
                    $provenance =
                        "Foreign"
                }
            }

            Set-SetupArchiveEvidence `
                $archive.FullName `
                $provenance `
                $inspection `
                $cutover

            $renamed =
                Rename-SetupBackupForProvenance `
                    $archive.FullName `
                    $target `
                    $provenance `
                    $cutover

            Write-Host (
                "  [{0}/{1}] {2} {3}" -f
                $rollbackIndex,
                $rollbackArchives.Count,
                (Get-SetupProvenanceCode `
                    $provenance),
                ([IO.Path]::GetFileName(
                    $renamed)))
        }
        catch {
            Write-Host (
                "Rollback provenance warning: " +
                $archive.FullName +
                " | " +
                $_.Exception.Message) `
                -ForegroundColor Yellow
        }
    }

    # Baselines and Rollbacks are lazy storage categories.
    foreach ($directory in @(
        $baselineDirectory,
        $rollbackDirectory
    )) {
        try {
            if (Test-Path `
                -LiteralPath $directory `
                -PathType Container) {

                $remaining =
                    @(
                        Get-ChildItem `
                            -LiteralPath $directory `
                            -Force `
                            -ErrorAction Stop
                    )

                if ($remaining.Count -eq 0) {
                    Remove-Item `
                        -LiteralPath $directory `
                        -Force `
                        -ErrorAction Stop
                }
            }
        }
        catch { }
    }
}

function Normalize-CurrentBridgeLayout(
    $ExistingConfig,
    [string]$DataFolder,
    [string]$StorageFolder,
    [string]$TempFolder,
    [string]$LogFolder) {

    if (-not $ExistingConfig) {
        return
    }

    # Only archive_folder/recovery_folder identify the previous filesystem
    # model. The current model also has log_folder, so log_folder alone must
    # never trigger a previous-layout relocation prompt on later Repairs.
    $previousLayout =
        [bool]$ExistingConfig.archive_folder -or
        [bool]$ExistingConfig.recovery_folder

    if (-not $previousLayout) {
        return
    }

    $previousStorage =
        $null

    $previousTemp =
        $null

    $previousLogs =
        $null

    if ($ExistingConfig.archive_folder) {
        $previousStorage =
            [IO.Path]::GetFullPath(
                [string]$ExistingConfig.archive_folder).TrimEnd('\')
    }

    if ($ExistingConfig.recovery_folder) {
        $previousTemp =
            [IO.Path]::GetFullPath(
                [string]$ExistingConfig.recovery_folder).TrimEnd('\')
    }

    if ($ExistingConfig.log_folder) {
        $previousLogs =
            [IO.Path]::GetFullPath(
                [string]$ExistingConfig.log_folder).TrimEnd('\')
    }

    $hasPrevious =
        (
            $previousStorage -and
            (Test-Path `
                -LiteralPath $previousStorage `
                -PathType Container)
        ) -or
        (
            $previousTemp -and
            (Test-Path `
                -LiteralPath $previousTemp `
                -PathType Container)
        ) -or
        (
            $previousLogs -and
            (Test-Path `
                -LiteralPath $previousLogs `
                -PathType Container)
        )

    if (-not $hasPrevious) {
        return
    }

    $sameStorage =
        $previousStorage -and
        $previousStorage.Equals(
            $StorageFolder,
            [StringComparison]::OrdinalIgnoreCase)

    $sameTemp =
        $previousTemp -and
        $previousTemp.Equals(
            $TempFolder,
            [StringComparison]::OrdinalIgnoreCase)

    $sameLogs =
        $previousLogs -and
        $previousLogs.Equals(
            $LogFolder,
            [StringComparison]::OrdinalIgnoreCase)

    if ($sameStorage -and
        $sameTemp -and
        $sameLogs) {

        return
    }

    $move =
        $true

    if (-not $Quiet) {
        Write-Host
        Write-Host "Existing Sierra History Bridge files use the previous folder layout."
        Write-Host "They can be moved into the current HistoryBridge layout now."

        $answer =
            Read-Host "Move existing bridge files to the current layout? [Y/n]"

        if (-not [string]::IsNullOrWhiteSpace(
                $answer)) {

            $move =
                $answer.Trim().ToLowerInvariant() -in @(
                    "y",
                    "yes")
        }
    }

    if (-not $move) {
        throw (
            "Repair canceled. Existing bridge files were left untouched; " +
            "the current layout was not activated.")
    }

    if ($previousStorage -and
        -not $sameStorage -and
        (Test-Path `
            -LiteralPath $previousStorage `
            -PathType Container)) {

        $categoryMap =
            [ordered]@{
                "SC_Data" = "Archive"
                "Rithmic_Baselines" = "Baselines"
                "Rollbacks" = "Rollbacks"
                "Restore_Conflicts" = "RestoreConflicts"
            }

        foreach ($entry in $categoryMap.GetEnumerator()) {
            $source =
                Join-Path `
                    $previousStorage `
                    $entry.Key

            if (Test-Path `
                -LiteralPath $source `
                -PathType Container) {

                $destination =
                    Join-Path `
                        $StorageFolder `
                        $entry.Value

                $filenameCode =
                    switch ($entry.Value) {
                        "Baselines" {
                            "UN"
                        }

                        "Rollbacks" {
                            "UN"
                        }

                        default {
                            $null
                        }
                    }

                [void](Move-LayoutDirectoryContents `
                    $source `
                    $destination `
                    $true `
                    $filenameCode)

                $provenance =
                    switch ($entry.Value) {
                        "Archive" {
                            "SCData"
                        }

                        "Baselines" {
                            "Unknown"
                        }

                        default {
                            "Unknown"
                        }
                    }

                Set-LayoutArchiveProvenance `
                    $destination `
                    $provenance
            }
        }

        $unexpected =
            @(
                Get-ChildItem `
                    -LiteralPath $previousStorage `
                    -Force `
                    -ErrorAction SilentlyContinue
            )

        if ($unexpected.Count -eq 0) {
            Remove-Item `
                -LiteralPath $previousStorage `
                -Force `
                -ErrorAction SilentlyContinue
        }
        else {
            Write-Host (
                "Previous storage contains unrecognized items and was left in place: " +
                $previousStorage) `
                -ForegroundColor Yellow
        }
    }

    if ($previousTemp -and
        -not $sameTemp -and
        (Test-Path `
            -LiteralPath $previousTemp `
            -PathType Container)) {

        $tempItems =
            @(
                Get-ChildItem `
                    -LiteralPath $previousTemp `
                    -Force `
                    -ErrorAction SilentlyContinue
            )

        if ($tempItems.Count -eq 0) {
            Remove-Item `
                -LiteralPath $previousTemp `
                -Force `
                -ErrorAction SilentlyContinue
        }
        else {
            [void](Move-LayoutDirectoryContents `
                $previousTemp `
                $TempFolder `
                $true `
                $null)
        }
    }

    if ($previousLogs -and
        -not $sameLogs -and
        (Test-Path `
            -LiteralPath $previousLogs `
            -PathType Container)) {

        [void](Move-LayoutDirectoryContents `
            $previousLogs `
            $LogFolder `
            $false `
            $null)
    }

}

function Configure-UserPaths([bool]$IsRepair) {
    $existingConfig =
        Read-SetupConfig

    $currentSierra =
        Get-DefaultSierraPath

    if (-not $currentSierra) {
        if ($Quiet) {
            throw "Sierra Chart installation path could not be detected."
        }

        $currentSierra =
            Read-SetupFolder `
                "Sierra Chart installation folder" `
                $null `
                $true
    }

    if (-not (
        Test-SierraPath `
            $currentSierra)) {

        throw (
            "The selected folder does not appear to be a Sierra Chart installation: " +
            $currentSierra)
    }

    $currentData =
        Get-DefaultSierraDataFolder `
            $currentSierra

    if (-not $currentData) {
        if ($Quiet) {
            throw "Sierra Chart Data folder could not be detected."
        }

        $currentData =
            Read-SetupFolder `
                "Sierra Chart Data folder" `
                (Join-Path `
                    $currentSierra `
                    "Data") `
                $true
    }

    $currentStorage =
        if ($existingConfig -and
            $existingConfig.storage_folder) {

            [IO.Path]::GetFullPath(
                [string]$existingConfig.storage_folder).TrimEnd('\')
        }
        else {
            Join-Path `
                $currentData `
                "HistoryBridge"
        }

    $currentLogs =
        if ($existingConfig -and
            $existingConfig.log_folder -and
            $existingConfig.sierra_path) {

            [IO.Path]::GetFullPath(
                [string]$existingConfig.log_folder).TrimEnd('\')
        }
        else {
            Join-Path `
                (Join-Path `
                    $currentSierra `
                    "Logs") `
                "HistoryBridge"
        }

    $changePaths =
        -not $IsRepair

    if ($IsRepair -and
        -not $Quiet) {

        Write-Host
        Write-Host "Configured Sierra instance:"
        Write-Host "  Sierra:   $currentSierra"
        Write-Host "  Data:     $currentData"
        Write-Host "  Storage:  $currentStorage"
        Write-Host (
            "  Temp:     {0}" -f
            (Join-Path `
                $currentData `
                "HistoryBridgeTemp"))
        Write-Host "  Logs:     $currentLogs"

        $answer =
            Read-Host "Change these paths? [y/N]"

        $changePaths =
            $answer.Trim().ToLowerInvariant() -in @(
                "y",
                "yes")
    }

    $sierra =
        $currentSierra

    $data =
        $currentData

    $storage =
        $currentStorage

    $logs =
        $currentLogs

    if ($changePaths) {
        $sierra =
            Read-SetupFolder `
                "Sierra Chart installation folder" `
                $currentSierra `
                $true

        if (-not (
            Test-SierraPath `
                $sierra)) {

            throw (
                "The selected folder does not appear to be a Sierra Chart installation: " +
                $sierra)
        }

        $dataDefault =
            if ($currentData -and
                $currentData.StartsWith(
                    $currentSierra + '\',
                    [StringComparison]::OrdinalIgnoreCase)) {

                Join-Path `
                    $sierra `
                    "Data"
            }
            else {
                $currentData
            }

        $data =
            Read-SetupFolder `
                "Sierra Chart Data folder" `
                $dataDefault `
                $true

        $storageDefault =
            if ($currentStorage -and
                $currentStorage.StartsWith(
                    $currentData + '\',
                    [StringComparison]::OrdinalIgnoreCase)) {

                Join-Path `
                    $data `
                    "HistoryBridge"
            }
            else {
                $currentStorage
            }

        $logsDefault =
            Join-Path `
                (Join-Path `
                    $sierra `
                    "Logs") `
                "HistoryBridge"

        $customize =
            $false

        if (-not $Quiet) {
            Write-Host

            $answer =
                Read-Host (
                    "Customize persistent storage or log folders? [y/N]")

            $customize =
                $answer.Trim().ToLowerInvariant() -in @(
                    "y",
                    "yes")
        }

        if ($customize) {
            $storage =
                Read-SetupFolder `
                    "HistoryBridge storage folder" `
                    $storageDefault `
                    $false

            $logs =
                Read-SetupFolder `
                    "HistoryBridge log folder" `
                    $logsDefault `
                    $false
        }
        else {
            $storage =
                $storageDefault

            $logs =
                $logsDefault
        }
    }

    $temp =
        Join-Path `
            $data `
            "HistoryBridgeTemp"

    foreach ($pair in @(
        [pscustomobject]@{
            Name = "Storage"
            Path = $storage
        },
        [pscustomobject]@{
            Name = "Temp"
            Path = $temp
        },
        [pscustomobject]@{
            Name = "Logs"
            Path = $logs
        }
    )) {
        $pair.Path =
            [IO.Path]::GetFullPath(
                $pair.Path).TrimEnd('\')
    }

    $storageDomains =
        @(
            [pscustomobject]@{
                Name = "Storage"
                Path = $storage
            },
            [pscustomobject]@{
                Name = "Temp"
                Path = $temp
            },
            [pscustomobject]@{
                Name = "Logs"
                Path = $logs
            }
        )

    for ($leftIndex = 0;
        $leftIndex -lt $storageDomains.Count;
        $leftIndex++) {

        for ($rightIndex =
                $leftIndex + 1;
            $rightIndex -lt
                $storageDomains.Count;
            $rightIndex++) {

            $left =
                [IO.Path]::GetFullPath(
                    $storageDomains[
                        $leftIndex].Path).TrimEnd('\')

            $right =
                [IO.Path]::GetFullPath(
                    $storageDomains[
                        $rightIndex].Path).TrimEnd('\')

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
                    $storageDomains[$leftIndex].Name +
                    " and " +
                    $storageDomains[$rightIndex].Name +
                    " folders must be separate.")
            }
        }
    }

    Normalize-CurrentBridgeLayout `
        $existingConfig `
        $data `
        $storage `
        $temp `
        $logs

    [void](Remove-SetupHeaderOnlyArchives `
        $storage)

    [void](Remove-SetupHeaderOnlyTempFiles `
        $temp)

    # Normalize provenance/filename codes for the current storage too. After
    # the first classification, known metadata avoids expensive reinspection.
    Normalize-RithmicBackupProvenance `
        $storage `
        $data `
        $existingConfig

    # Logs exist because Setup itself is an operation. Persistent storage and
    # temp folders remain lazy and are created only when required.
    New-Item `
        -ItemType Directory `
        -Path $logs `
        -Force |
        Out-Null

    $provenScales =
        @{}

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
            sierra_path = $sierra
            default_data_folder = $data
            storage_folder = $storage
            log_folder = $logs
        }

    $configPath =
        Join-Path `
            $UserDataRoot `
            "config.json"

    $settings |
        ConvertTo-Json `
            -Depth 8 |
        Set-Content `
            -LiteralPath $configPath `
            -Encoding UTF8

    Set-SetupLogDestination `
        $logs

    Write-SetupLog (
        "Configured Sierra instance: sierra={0}; data={1}; storage={2}; temp={3}; logs={4}" -f
        $sierra,
        $data,
        $storage,
        $temp,
        $logs)

    return [pscustomobject]@{
        Sierra = $sierra
        Data = $data
        Storage = $storage
        Temp = $temp
        Logs = $logs
    }
}

function New-ExplorerVerb(
    [string]$Path,
    [string]$Title,
    [string]$Command,
    [string]$Icon,
    [string]$AppliesTo,
    [string]$MultiSelectModel) {

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

    if ($MultiSelectModel) {
        New-ItemProperty `
            -LiteralPath $Path `
            -Name "MultiSelectModel" `
            -Value $MultiSelectModel `
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
        "rollback.cmd",
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
            "rollback.cmd",
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

function Test-PayloadRuntime([string]$InstallDirectory) {
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
            "The package application script did not pass PowerShell syntax validation " +
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

    $shellRoots =
        @(
            "$classesRoot\Directory\shell",
            "$classesRoot\Directory\Background\shell",
            "$classesRoot\SystemFileAssociations\.scid\shell",
            "$classesRoot\SystemFileAssociations\.dly\shell",
            "$classesRoot\SystemFileAssociations\.gz\shell"
        )

    foreach ($root in $shellRoots) {
        if (-not (
            Test-Path `
                -LiteralPath $root)) {
            continue
        }

        foreach ($key in @(
            Get-ChildItem `
                -LiteralPath $root `
                -ErrorAction SilentlyContinue)) {

            if ($key.PSChildName.Equals(
                    $ProductKey,
                    [StringComparison]::OrdinalIgnoreCase) -or
                $key.PSChildName.StartsWith(
                    $ProductKey + ".",
                    [StringComparison]::OrdinalIgnoreCase)) {

                Remove-Item `
                    -LiteralPath $key.PSPath `
                    -Recurse `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
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

    $sierraFolder =
        [IO.Path]::GetFullPath(
            [string]$Settings.Sierra).TrimEnd('\')

    $dataFolder =
        [IO.Path]::GetFullPath(
            [string]$Settings.Data).TrimEnd('\')

    $storageFolder =
        [IO.Path]::GetFullPath(
            [string]$Settings.Storage).TrimEnd('\')

    $folderAppliesTo =
        'System.ItemPathDisplay:="' +
        $dataFolder +
        '"'

    $dataFileAppliesTo =
        'System.ItemFolderPathDisplay:="' +
        $dataFolder +
        '"'

    # AQS starts-with comparison scopes static file verbs to configured roots.
    $sourceArchiveFolder =
        Join-Path $storageFolder "Archive"

    $archiveFileAppliesTo =
        'System.ItemPathDisplay:~<"' +
        $sourceArchiveFolder +
        '\' +
        '"'

    $baseCommand =
        '"' + $PowerShellExe + '"' +
        ' -NoLogo -NoProfile -ExecutionPolicy Bypass' +
        ' -File "' + $installedScript + '"' +
        ' -DataFolder "' + $dataFolder + '"' +
        ' -SierraPath "' + $sierraFolder + '"'

    $dispatchBase =
        '"' + $PowerShellExe + '"' +
        ' -NoLogo -NoProfile -ExecutionPolicy Bypass' +
        ' -WindowStyle Hidden' +
        ' -File "' + $installedScript + '"' +
        ' -DataFolder "' + $dataFolder + '"' +
        ' -SierraPath "' + $sierraFolder + '"' +
        ' -Mode Explorer'

    New-ExplorerVerb `
        "$classesRoot\Directory\shell\$ProductKey.Update" `
        "Update History" `
        ($baseCommand + ' -Mode Update -Interactive') `
        $icon `
        $folderAppliesTo `
        "Single"

    New-ExplorerVerb `
        "$classesRoot\Directory\shell\$ProductKey.Storage" `
        "Storage Report" `
        ($baseCommand + ' -Mode Storage -Interactive') `
        "$env:SystemRoot\System32\shell32.dll,4" `
        $folderAppliesTo `
        "Single"

    foreach ($extension in @(".scid", ".dly")) {
        $sourceFileAppliesTo =
            $dataFileAppliesTo +
            ' AND System.FileName:"*-*' +
            $extension +
            '"'

        New-ExplorerVerb `
            "$classesRoot\SystemFileAssociations\$extension\shell\$ProductKey.Archive" `
            "Archive SC Data" `
            ($dispatchBase + ' -DispatchMode Archive -SelectedFile "%1"') `
            "$env:SystemRoot\System32\shell32.dll,46" `
            $sourceFileAppliesTo `
            "Player"
    }

    New-ExplorerVerb `
        "$classesRoot\SystemFileAssociations\.gz\shell\$ProductKey.Restore" `
        "Restore SC Data" `
        ($dispatchBase + ' -DispatchMode Restore -SelectedFile "%1"') `
        "$env:SystemRoot\System32\shell32.dll,167" `
        $archiveFileAppliesTo `
        "Player"


    foreach ($rollbackScope in @(
        [pscustomobject]@{
            Key = "$ProductKey.RollbackBaseline"
            Path = Join-Path $storageFolder "Baselines"
        },
        [pscustomobject]@{
            Key = "$ProductKey.RollbackCurrent"
            Path = Join-Path $storageFolder "Rollbacks"
        }
    )) {
        $rollbackAppliesTo =
            'System.ItemPathDisplay:~<"' +
            ([IO.Path]::GetFullPath(
                $rollbackScope.Path).TrimEnd('\')) +
            '\' +
            '"'

        New-ExplorerVerb `
            "$classesRoot\SystemFileAssociations\.gz\shell\$($rollbackScope.Key)" `
            "Rollback Rithmic" `
            ($dispatchBase + ' -DispatchMode Rollback -SelectedFile "%1"') `
            "$env:SystemRoot\System32\shell32.dll,167" `
            $rollbackAppliesTo `
            "Player"
    }
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
        -ShortcutPath (Join-Path $directory "Archive SC Data.lnk") `
        -TargetPath $PowerShellExe `
        -Arguments ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $mainScript + '" -Mode Archive -Interactive') `
        -WorkingDirectory $InstallDirectory `
        -Description "Archive selected SC Data files with verified compression." `
        -IconLocation "$env:SystemRoot\System32\shell32.dll,46"

    New-Shortcut `
        -ShortcutPath (Join-Path $directory "Restore SC Data.lnk") `
        -TargetPath $PowerShellExe `
        -Arguments ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $mainScript + '" -Mode Restore -Interactive') `
        -WorkingDirectory $InstallDirectory `
        -Description "Restore verified SC Data archives to Sierra Chart." `
        -IconLocation "$env:SystemRoot\System32\shell32.dll,167"

    New-Shortcut `
        -ShortcutPath (Join-Path $directory "Rollback Rithmic.lnk") `
        -TargetPath $PowerShellExe `
        -Arguments ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $mainScript + '" -Mode Rollback -Interactive') `
        -WorkingDirectory $InstallDirectory `
        -Description "Restore a verified Rithmic baseline or rollback backup." `
        -IconLocation "$env:SystemRoot\System32\shell32.dll,167"

    New-Shortcut `
        -ShortcutPath (Join-Path $directory "Storage Report.lnk") `
        -TargetPath $PowerShellExe `
        -Arguments ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $mainScript + '" -Mode Storage -Interactive') `
        -WorkingDirectory $InstallDirectory `
        -Description "Show Sierra Chart Data, HistoryBridge, temp, and free-space usage." `
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
        Comments = "Maintains Rithmic Sierra Chart history from SC Data sources."
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

    $validationDirectory =
        Join-Path `
            $env:TEMP `
            ("SierraHistoryBridge-Validate-" +
                [guid]::NewGuid().ToString("N"))

    try {
        $payload =
            Resolve-PayloadRoot `
                $ResolvedSourceRoot `
                $installDirectory

        # Validate the exact package payload before touching the installed app.
        Copy-ApplicationPayload `
            $payload.Root `
            $validationDirectory

        Test-PayloadRuntime `
            $validationDirectory

        Copy-ApplicationPayload `
            $payload.Root `
            $installDirectory

        New-InstalledRepairPayload `
            $installDirectory

        $settings =
            Configure-UserPaths $IsRepair

        Install-ExplorerIntegration `
            $InstallScope `
            $installDirectory `
            $settings

        Install-StartMenuShortcuts $InstallScope $installDirectory $CreateStartMenu
        Register-Uninstaller $InstallScope $installDirectory $CreateStartMenu

        Write-SetupLog "$($(if ($IsRepair) { 'Repair' } else { 'Install' })) completed: scope=$InstallScope path=$installDirectory"

        Write-Host
        Write-Host "Completed successfully." -ForegroundColor Green
        Write-Host
        Write-Host "Sierra instance:"
        Write-Host "  Sierra:  $($settings.Sierra)"
        Write-Host "  Data:    $($settings.Data)"
        Write-Host "  Storage: $($settings.Storage)"
        Write-Host "  Temp:    $($settings.Temp)"
        Write-Host "  Logs:    $($settings.Logs)"
        Write-Host
        Write-Host "Explorer commands:"
        Write-Host "  Data folder: Update History, Storage Report"
        Write-Host "  SC Data files: Archive SC Data"
        Write-Host "  SC Data archives: Restore SC Data"
        Write-Host "  Rithmic backups: Rollback Rithmic"
        Write-Host
        Write-Host "Windows Settings:"
        Write-Host "  $ProductName is registered under Installed apps for standard removal."
        if ($CreateStartMenu) {
            Write-Host
            Write-Host "Start Menu / All apps:"
            Write-Host "  $ProductName"
            Write-Host "  Archive SC Data"
            Write-Host "  Restore SC Data"
            Write-Host "  Rollback Rithmic"
            Write-Host "  Storage Report"
            Write-Host "  Repair $ProductName"
            Write-Host "  Uninstall $ProductName"
            Write-Host "  $ProductName Documentation"
        }
    }
    finally {
        if (Test-Path `
            -LiteralPath $validationDirectory) {

            Remove-Item `
                -LiteralPath $validationDirectory `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }

        if ($payload -and $payload.Temporary -and
            (Test-Path -LiteralPath $payload.Root)) {

            Remove-Item `
                -LiteralPath $payload.Root `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
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

    $savedConfig =
        Read-SetupConfig

    $tempRetained =
        $false

    if ($savedConfig -and
        $savedConfig.default_data_folder) {

        try {
            $bridgeTemp =
                Join-Path `
                    ([IO.Path]::GetFullPath(
                        [string]$savedConfig.default_data_folder).TrimEnd('\')) `
                    "HistoryBridgeTemp"

            if (Test-Path `
                -LiteralPath $bridgeTemp `
                -PathType Container) {

                $remaining =
                    @(
                        Get-ChildItem `
                            -LiteralPath $bridgeTemp `
                            -Force `
                            -ErrorAction Stop
                    )

                if ($remaining.Count -eq 0) {
                    Remove-Item `
                        -LiteralPath $bridgeTemp `
                        -Force `
                        -ErrorAction Stop
                }
                else {
                    $tempRetained =
                        $true
                }
            }
        }
        catch {
            $tempRetained =
                $true
        }
    }

    # Explorer batching is purely transient and never user data.
    Remove-Item `
        -LiteralPath (
            Join-Path `
                $env:TEMP `
                "SierraHistoryBridge") `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue

    $removeData = Ask-RemoveUserData

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
    Write-Host "Persistent HistoryBridge storage and logs were left in their"
    Write-Host "configured locations."

    if ($tempRetained) {
        Write-Host (
            "Non-empty HistoryBridgeTemp data was retained for review.") `
            -ForegroundColor Yellow
    }
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
    Write-SetupLog $_.Exception.ToString() "ERROR"
    Write-Host
    Write-Host "Setup error" -ForegroundColor Red
    Write-Host $_.Exception.Message
    Write-Host
    Write-Host "Setup log:"
    Write-Host "  $SetupLog"
}

Pause-IfInteractive
exit $exitCode

