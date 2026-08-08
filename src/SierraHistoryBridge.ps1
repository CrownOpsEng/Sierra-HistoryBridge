# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [string]$DataFolder,
    [ValidateSet("Update", "Archive", "Restore", "Storage")]
    [string]$Mode = "Update",
    [string]$FromDate,
    [string]$ToDate,
    [int]$Days = 0,
    [switch]$All,
    [string]$SelectedFile,
    [switch]$Interactive,
    [switch]$Force,
    [switch]$DryRun,
    [switch]$Yes
)

$ErrorActionPreference = "Stop"

$Version = "0.0.22"
$AppName = "SierraHistoryBridge"
$AppDataDirectory = Join-Path $env:LOCALAPPDATA $AppName
$ConfigPath = Join-Path $AppDataDirectory "config.json"
$StatePath = Join-Path $AppDataDirectory "state.json"
$SourceDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConverterSource = Join-Path $SourceDirectory "ScidBridge.cs"

New-Item -ItemType Directory -Force -Path $AppDataDirectory | Out-Null

$script:DeferredCleanupDirectories = @()
$script:CleanupDataFolder = $null
$script:UtilityTranscriptActive = $false
$script:UtilityLogPath = $null

function Show-Banner {
    Clear-Host
    Write-Host "================================================================"
    Write-Host " Sierra History Bridge v$Version"
    Write-Host "================================================================"
    Write-Host "Updates Rithmic-named Sierra Chart intraday and daily files with"
    Write-Host "SC Data history while preserving newer Rithmic records."
    Write-Host
}

function Format-CompactCount([long]$Value) {
    if ($Value -ge 1000000000) {
        return "{0:0.00}B" -f ($Value / 1000000000.0)
    }
    if ($Value -ge 1000000) {
        return "{0:0.00}M" -f ($Value / 1000000.0)
    }
    if ($Value -ge 1000) {
        return "{0:0.0}K" -f ($Value / 1000.0)
    }
    return [string]$Value
}

function Format-CompactSize([long]$Bytes) {
    if ($Bytes -ge 1GB) {
        return "{0:0.00} GB" -f ($Bytes / 1GB)
    }
    if ($Bytes -ge 1MB) {
        return "{0:0.0} MB" -f ($Bytes / 1MB)
    }
    if ($Bytes -ge 1KB) {
        return "{0:0.0} KB" -f ($Bytes / 1KB)
    }
    return "$Bytes B"
}

function Get-CompactName([string]$FileName) {
    foreach ($extension in @(".scid", ".dly")) {
        if ($FileName.EndsWith(
            $extension,
            [StringComparison]::OrdinalIgnoreCase)) {

            return $FileName.Substring(
                0,
                $FileName.Length - $extension.Length)
        }
    }

    return $FileName
}

function Get-FuturesMonthNumber([string]$MonthCode) {
    switch ($MonthCode.ToUpperInvariant()) {
        "F" { return 1 }
        "G" { return 2 }
        "H" { return 3 }
        "J" { return 4 }
        "K" { return 5 }
        "M" { return 6 }
        "N" { return 7 }
        "Q" { return 8 }
        "U" { return 9 }
        "V" { return 10 }
        "X" { return 11 }
        "Z" { return 12 }
        default { throw "Unknown futures month code: $MonthCode" }
    }
}

function Get-ContractMonth([int]$FullYear, [string]$MonthCode) {
    return [datetime]::new(
        $FullYear,
        (Get-FuturesMonthNumber $MonthCode),
        1)
}

function Resolve-FullContractYear([string]$TwoDigitYear) {
    $year = [int]$TwoDigitYear
    $currentYear = (Get-Date).Year
    $century = [int]([Math]::Floor($currentYear / 100.0) * 100)
    $candidate = $century + $year

    if ($candidate -gt ($currentYear + 50)) {
        $candidate -= 100
    }
    elseif ($candidate -lt ($currentYear - 49)) {
        $candidate += 100
    }

    return $candidate
}

function Get-BridgeWindow {
    $currentMonth =
        [datetime]::new(
            (Get-Date).Year,
            (Get-Date).Month,
            1)

    $windowStart =
        $currentMonth.AddYears(-5).AddMonths(-3)

    $windowEnd =
        $currentMonth.AddMonths(6)

    return [pscustomobject]@{
        Start = $windowStart
        End = $windowEnd
    }
}

function Test-ContractInRithmicWindow(
    [datetime]$ContractMonth,
    [datetime]$WindowStart,
    [datetime]$WindowEnd) {

    return (
        $ContractMonth -ge $WindowStart -and
        $ContractMonth -le $WindowEnd)
}


function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{}
    }

    try {
        $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($content)) {
            return [pscustomobject]@{}
        }
        return $content | ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{}
    }
}

function Save-JsonFile([string]$Path, $Object) {
    $temporaryPath = "$Path.tmp"
    $Object | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Normalize-DataFolder([string]$RawPath) {
    if ([string]::IsNullOrWhiteSpace($RawPath)) {
        return $null
    }

    $path = $RawPath.Trim().Trim('"').Trim("'")
    $path = [Environment]::ExpandEnvironmentVariables($path)

    try {
        $path = [IO.Path]::GetFullPath($path)
    }
    catch {
        return $null
    }

    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $path = Split-Path -Parent $path
    }

    if ((Test-Path -LiteralPath $path -PathType Container) -and
        ([IO.Path]::GetFileName($path) -ine "Data")) {
        $childData = Join-Path $path "Data"
        if (Test-Path -LiteralPath $childData -PathType Container) {
            $path = $childData
        }
    }

    if (Test-Path -LiteralPath $path -PathType Container) {
        return $path
    }

    return $null
}

function Get-SierraDataFolder([string]$ExplicitPath) {
    if ($ExplicitPath) {
        $resolved = Normalize-DataFolder $ExplicitPath
        if (-not $resolved) {
            throw "The selected Sierra Chart folder does not exist: $ExplicitPath"
        }
        return $resolved
    }

    $candidates = New-Object System.Collections.Generic.List[string]

    function Add-Candidate([string]$CandidatePath) {
        $normalized = Normalize-DataFolder $CandidatePath
        if ($normalized -and -not $candidates.Contains($normalized)) {
            $candidates.Add($normalized)
        }
    }

    $config = Read-JsonFile $ConfigPath
    if ($config.default_data_folder) {
        Add-Candidate ([string]$config.default_data_folder)
    }

    try {
        Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -like "SierraChart*" } |
            ForEach-Object {
                try {
                    if ($_.Path) {
                        Add-Candidate (Join-Path (Split-Path -Parent $_.Path) "Data")
                    }
                }
                catch { }
            }
    }
    catch { }

    Add-Candidate (Get-Location).Path
    Add-Candidate $SourceDirectory
    Add-Candidate (Split-Path -Parent $SourceDirectory)

    foreach ($drive in @("C:", "D:", "E:", "F:", "G:")) {
        Add-Candidate "$drive\SierraChart\Data"
        Add-Candidate "$drive\SierraChart64\Data"
        Add-Candidate "$drive\SierraChart_64\Data"
    }

    if ($candidates.Count -gt 0) {
        $default = $candidates[0]
        Write-Host "Sierra Chart Data folder:"
        Write-Host "  $default"
        $response = Read-Host "Press Enter to use it, or paste another folder"
        if ([string]::IsNullOrWhiteSpace($response)) {
            return $default
        }

        $resolved = Normalize-DataFolder $response
        if (-not $resolved) {
            throw "That folder does not exist."
        }
        return $resolved
    }

    $response = Read-Host "Paste or drag the Sierra Chart Data folder here"
    $resolved = Normalize-DataFolder $response
    if (-not $resolved) {
        throw "No valid Sierra Chart Data folder was selected."
    }
    return $resolved
}

function Get-NormalizedConfiguredPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    try {
        return [IO.Path]::GetFullPath(
            $Path.Trim().Trim('"')).TrimEnd('\')
    }
    catch {
        return $null
    }
}

function Get-BridgePaths([string]$ResolvedDataFolder) {
    $data =
        [IO.Path]::GetFullPath(
            $ResolvedDataFolder).TrimEnd('\')

    $config = Read-JsonFile $ConfigPath

    $configuredData =
        Get-NormalizedConfiguredPath `
            ([string]$config.default_data_folder)

    $useConfigured =
        $configuredData -and
        $configuredData.Equals(
            $data,
            [StringComparison]::OrdinalIgnoreCase)

    $archive =
        Join-Path $data "SCID_Bridge_Archive"

    $recovery =
        Join-Path $data "SCID_Bridge_Backups"

    $logs =
        Join-Path $data "SCID_Bridge_Logs"

    if ($useConfigured) {
        $candidate =
            Get-NormalizedConfiguredPath `
                ([string]$config.archive_folder)
        if ($candidate) {
            $archive = $candidate
        }

        $candidate =
            Get-NormalizedConfiguredPath `
                ([string]$config.recovery_folder)
        if ($candidate) {
            $recovery = $candidate
        }

        $candidate =
            Get-NormalizedConfiguredPath `
                ([string]$config.log_folder)
        if ($candidate) {
            $logs = $candidate
        }
    }

    return [pscustomobject]@{
        Data = $data
        Archive = $archive
        Recovery = $recovery
        Logs = $logs
    }
}

function Start-UtilityOperationLog(
    [string]$Operation,
    [string]$ResolvedDataFolder) {

    if ($Operation -eq "Update") {
        return $null
    }

    $bridgePaths =
        Get-BridgePaths $ResolvedDataFolder

    New-Item `
        -ItemType Directory `
        -Path $bridgePaths.Logs `
        -Force |
        Out-Null

    $stamp =
        (Get-Date).ToUniversalTime().ToString(
            "yyyyMMdd-HHmmss")

    $safeOperation =
        $Operation.ToLowerInvariant()

    $logPath =
        Join-Path `
            $bridgePaths.Logs `
            ("{0}-{1}.log" -f
                $safeOperation,
                $stamp)

    try {
        Start-Transcript `
            -Path $logPath `
            -Force |
            Out-Null

        $script:UtilityTranscriptActive = $true
        $script:UtilityLogPath = $logPath

        Write-Host "Log:       $logPath"

        return $logPath
    }
    catch {
        Write-Host (
            "LOG WARNING: could not start operation log: " +
            $_.Exception.Message) `
            -ForegroundColor Yellow

        return $null
    }
}

function Stop-UtilityOperationLog {
    if (-not $script:UtilityTranscriptActive) {
        return
    }

    try {
        Stop-Transcript |
            Out-Null
    }
    catch { }

    $script:UtilityTranscriptActive = $false
}

function Add-DeferredDirectoryCleanup(
    [string]$Directory,
    [string]$ProtectedRoot) {

    if ([string]::IsNullOrWhiteSpace($Directory) -or
        [string]::IsNullOrWhiteSpace($ProtectedRoot)) {
        return $false
    }

    $directoryPath =
        [IO.Path]::GetFullPath(
            $Directory).TrimEnd('\')

    $rootPath =
        [IO.Path]::GetFullPath(
            $ProtectedRoot).TrimEnd('\')

    foreach ($item in $script:DeferredCleanupDirectories) {
        if ($item.Directory.Equals(
                $directoryPath,
                [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }

    $script:DeferredCleanupDirectories +=
        [pscustomobject]@{
            Directory = $directoryPath
            ProtectedRoot = $rootPath
        }

    return $true
}

function Start-DeferredDirectoryCleanupWorker {
    if ($script:DeferredCleanupDirectories.Count -eq 0 -or
        [string]::IsNullOrWhiteSpace(
            $script:CleanupDataFolder)) {
        return $null
    }

    $bridgePaths =
        Get-BridgePaths `
            $script:CleanupDataFolder

    New-Item `
        -ItemType Directory `
        -Path $bridgePaths.Logs `
        -Force |
        Out-Null

    $stamp =
        (Get-Date).ToUniversalTime().ToString(
            "yyyyMMdd-HHmmss")

    $logPath =
        Join-Path `
            $bridgePaths.Logs `
            ("cleanup-{0}.log" -f $stamp)

    $payloadJson =
        @($script:DeferredCleanupDirectories) |
        ConvertTo-Json `
            -Depth 4 `
            -Compress

    $payload64 =
        [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes(
                $payloadJson))

    $log64 =
        [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes(
                $logPath))

    $parentPid =
        [int]$PID

    $worker = @'
$ErrorActionPreference = "Continue"

$parentPid = __PARENT_PID__
$payload64 = "__PAYLOAD64__"
$log64 = "__LOG64__"

$payloadJson =
    [Text.Encoding]::Unicode.GetString(
        [Convert]::FromBase64String(
            $payload64))

$logPath =
    [Text.Encoding]::Unicode.GetString(
        [Convert]::FromBase64String(
            $log64))

$items =
    @(
        $payloadJson |
        ConvertFrom-Json
    )

$lines = @()
$lines +=
    "Sierra History Bridge deferred cleanup"
$lines +=
    "Started UTC: " +
    (Get-Date).ToUniversalTime().ToString("o")
$lines +=
    "Waiting for parent PID: " +
    $parentPid

try {
    Wait-Process `
        -Id $parentPid `
        -ErrorAction SilentlyContinue
}
catch { }

Start-Sleep -Milliseconds 250

foreach ($item in $items) {
    $current =
        [IO.Path]::GetFullPath(
            [string]$item.Directory).TrimEnd('\')

    $root =
        [IO.Path]::GetFullPath(
            [string]$item.ProtectedRoot).TrimEnd('\')

    $lines +=
        "Cleanup root: " +
        $root

    while (
        -not $current.Equals(
            $root,
            [StringComparison]::OrdinalIgnoreCase) -and
        $current.StartsWith(
            $root + '\',
            [StringComparison]::OrdinalIgnoreCase)) {

        if (-not (
            Test-Path `
                -LiteralPath $current `
                -PathType Container)) {

            $parent =
                Split-Path `
                    -Parent `
                    $current

            if ([string]::IsNullOrWhiteSpace(
                $parent)) {
                break
            }

            $current =
                [IO.Path]::GetFullPath(
                    $parent).TrimEnd('\')

            continue
        }

        $remaining =
            @(
                Get-ChildItem `
                    -LiteralPath $current `
                    -Force `
                    -ErrorAction SilentlyContinue
            )

        if ($remaining.Count -gt 0) {
            $lines +=
                "KEEP non-empty: " +
                $current
            break
        }

        $deleted = $false
        $lastError = $null

        for ($attempt = 1;
            $attempt -le 150;
            $attempt++) {

            try {
                Remove-Item `
                    -LiteralPath $current `
                    -Force `
                    -ErrorAction Stop

                $deleted = $true
                break
            }
            catch {
                $lastError =
                    $_.Exception.Message

                Start-Sleep `
                    -Milliseconds 200
            }
        }

        if (-not $deleted) {
            $lines +=
                "FAILED after parent exit: " +
                $current +
                " | " +
                $lastError
            break
        }

        $lines +=
            "REMOVED: " +
            $current

        $parent =
            Split-Path `
                -Parent `
                $current

        if ([string]::IsNullOrWhiteSpace(
            $parent)) {
            break
        }

        $current =
            [IO.Path]::GetFullPath(
                $parent).TrimEnd('\')
    }
}

$lines +=
    "Finished UTC: " +
    (Get-Date).ToUniversalTime().ToString("o")

try {
    $directory =
        Split-Path `
            -Parent `
            $logPath

    New-Item `
        -ItemType Directory `
        -Path $directory `
        -Force |
        Out-Null

    $lines |
        Set-Content `
            -LiteralPath $logPath `
            -Encoding UTF8
}
catch { }
'@

    $worker =
        $worker.Replace(
            "__PARENT_PID__",
            [string]$parentPid)

    $worker =
        $worker.Replace(
            "__PAYLOAD64__",
            $payload64)

    $worker =
        $worker.Replace(
            "__LOG64__",
            $log64)

    $encoded =
        [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes(
                $worker))

    $powershellExe =
        Join-Path `
            $PSHOME `
            "powershell.exe"

    Start-Process `
        -FilePath $powershellExe `
        -ArgumentList @(
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-WindowStyle",
            "Hidden",
            "-EncodedCommand",
            $encoded
        ) `
        -WorkingDirectory $script:CleanupDataFolder `
        -WindowStyle Hidden |
        Out-Null

    Write-Host
    Write-Host (
        "Cleanup deferred until this window closes. " +
        "A helper will retry for up to 30 seconds.") `
        -ForegroundColor Yellow
    Write-Host "Cleanup log: $logPath"

    return $logPath
}

function Wait-ForSierraChartClosed(
    [string]$Operation,
    [bool]$CanPrompt) {

    if (-not (Test-SierraChartRunning)) {
        return $true
    }

    if (-not $CanPrompt) {
        throw (
            "Sierra Chart is running. Close it before $Operation.")
    }

    Write-Host
    Write-Host "Sierra Chart is running." -ForegroundColor Yellow
    Write-Host (
        "$Operation requires Sierra Chart to be closed so files can be moved safely.")
    Write-Host

    while (Test-SierraChartRunning) {
        $answer =
            Read-Host (
                "Close Sierra Chart, then press Enter to continue; type C to cancel")

        if ($answer.Trim().ToLowerInvariant() -in @("c", "cancel")) {
            Write-Host "$Operation canceled."
            return $false
        }

        if (Test-SierraChartRunning) {
            Write-Host (
                "Sierra Chart is still running. Close all Sierra Chart instances first.") `
                -ForegroundColor Yellow
        }
    }

    Write-Host "Sierra Chart closed. Continuing."
    return $true
}

function Test-SierraChartRunning {
    $process = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -like "SierraChart*" } |
        Select-Object -First 1

    return $null -ne $process
}

function Convert-ScDateTimeToUtc([long]$Value) {
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

function Test-LiveScidCandidate($Candidate) {
    if (-not $Candidate.ScidNeeded) {
        return $false
    }

    # A seven-day data lookback covers normal weekends and exchange holidays.
    # It is intentionally conservative: the purpose is to identify intraday
    # targets that can still plausibly receive current service writes.
    $cutoff =
        (Get-Date).ToUniversalTime().AddDays(-7)

    $sourceLast =
        Convert-ScDateTimeToUtc ([long]$Candidate.Last)

    if ($sourceLast -and $sourceLast -ge $cutoff) {
        return $true
    }

    if ($Candidate.TargetStatus -and
        $Candidate.TargetStatus.LastDateTime -gt 0) {

        $targetLast =
            Convert-ScDateTimeToUtc (
                [long]$Candidate.TargetStatus.LastDateTime)

        if ($targetLast -and $targetLast -ge $cutoff) {
            return $true
        }
    }

    return $false
}

function Get-HistoricalScidDeferReason($Candidate) {
    if (-not $Candidate.ScidNeeded -or
        $Candidate.LiveScidUpdate) {
        return $null
    }

    try {
        $sourceItem =
            Get-Item -LiteralPath $Candidate.Source

        if ($sourceItem.LastWriteTimeUtc -ge
            (Get-Date).ToUniversalTime().AddSeconds(-5)) {

            return "source file was modified within the last 5 seconds"
        }
    }
    catch { }

    return $null
}

function Format-ScidDate([long]$Value) {
    $date = Convert-ScDateTimeToUtc $Value
    if ($date) {
        return $date.ToString("yyyy-MM-dd")
    }

    return "unknown"
}

function Get-ScidPairGrade($Validation) {
    if ($null -eq $Validation) {
        return "NONE"
    }

    if ($Validation.SourceOutOfOrderRecords -gt 0) {
        return "SOURCE-ANOMALY"
    }

    if ($Validation.CommonSeconds -lt 100) {
        return "INSUFFICIENT"
    }

    if ($Validation.CommonCoveragePercent -ge 99.0 -and
        $Validation.VolumeMatchPercent -ge 98.0 -and
        $Validation.LastPriceMatchPercent -ge 99.0 -and
        $Validation.AggregateVolumeDifferencePercent -le 0.5) {

        return "STRONG"
    }

    if ($Validation.CommonCoveragePercent -ge 95.0 -and
        $Validation.VolumeMatchPercent -ge 90.0 -and
        $Validation.LastPriceMatchPercent -ge 95.0 -and
        $Validation.AggregateVolumeDifferencePercent -le 2.0) {

        return "WARNING"
    }

    return "POOR"
}

function Get-ScidCoverageAssessment($Candidate, $Validation) {
    $sourceLast =
        Convert-ScDateTimeToUtc ([long]$Candidate.Last)

    $sourceFirst =
        Convert-ScDateTimeToUtc ([long]$Candidate.First)

    $targetLast = $null
    $targetFirst = $null

    if ($Validation) {
        $targetLast =
            Convert-ScDateTimeToUtc (
                [long]$Validation.TargetLastDateTime)

        $targetFirst =
            Convert-ScDateTimeToUtc (
                [long]$Validation.TargetFirstDateTime)
    }

    $dailyLast = $null
    if ($Candidate.DailyAvailable -and
        $Candidate.DailyLastDateTicks -gt 0) {

        $dailyLast =
            [datetime]::MinValue.AddTicks(
                [long]$Candidate.DailyLastDateTicks)
    }

    $sourceIncomplete = $false
    $targetExtendsLater = $false
    $targetStartsEarlier = $false
    $reasons =
        New-Object System.Collections.Generic.List[string]

    if ($sourceLast -and $dailyLast -and
        $sourceLast.Date -lt $dailyLast.Date.AddDays(-1)) {

        $sourceIncomplete = $true
        $reasons.Add(
            "source ends $($sourceLast.ToString('yyyy-MM-dd')); Daily history ends $($dailyLast.ToString('yyyy-MM-dd'))")
    }

    if ($sourceLast -and $targetLast -and
        $targetLast -gt $sourceLast.AddDays(1)) {

        $targetExtendsLater = $true
        $reasons.Add(
            "Rithmic target extends to $($targetLast.ToString('yyyy-MM-dd'))")
    }

    if ($sourceFirst -and $targetFirst -and
        $sourceFirst -gt $targetFirst.AddDays(1)) {

        $targetStartsEarlier = $true
        $reasons.Add(
            "Rithmic target starts earlier at $($targetFirst.ToString('yyyy-MM-dd'))")
    }

    return [pscustomobject]@{
        SourceIncomplete = $sourceIncomplete
        TargetExtendsLater = $targetExtendsLater
        TargetStartsEarlier = $targetStartsEarlier
        SourceFirst = $sourceFirst
        SourceLast = $sourceLast
        TargetFirst = $targetFirst
        TargetLast = $targetLast
        DailyLast = $dailyLast
        Summary = ($reasons -join "; ")
    }
}

function Get-ScidValidationSummary($Candidate) {
    if ($Candidate.ScidDeferred) {
        return "DEFERRED | $($Candidate.ScidDeferReason)"
    }

    if (-not $Candidate.ScidNeeded) {
        return "current"
    }

    if ($Candidate.LiveScidUpdate) {
        return "LIVE | overlap validation after disconnect/close"
    }

    if (-not $Candidate.TargetStatus.Exists) {
        if ($Candidate.ScidCoverage -and
            $Candidate.ScidCoverage.SourceIncomplete) {
            return "INCOMPLETE SOURCE | no Rithmic target available for comparison"
        }

        return "SOURCE VALID | CREATE | no independent Rithmic comparison"
    }

    if ($Candidate.TargetStatus.Kind -ne "data") {
        return "TARGET $($Candidate.TargetStatus.Kind.ToUpperInvariant()) | source will be used only if complete"
    }

    $v = $Candidate.ScidValidation
    if (-not $v) {
        return "validation unavailable"
    }

    $coverage =
        "coverage={0:0.000}%" -f
        $v.CommonCoveragePercent

    $volume =
        "volume/sec={0:0.000}%" -f
        $v.VolumeMatchPercent

    $price =
        "last-price={0:0.000}%" -f
        $v.LastPriceMatchPercent

    $aggregate =
        "aggregate-volume-diff={0:0.000000}%" -f
        $v.AggregateVolumeDifferencePercent

    $reference =
        if ($Candidate.ScidValidationReference) {
            "ref=$($Candidate.ScidValidationReference.Kind)"
        }
        else {
            "ref=unknown"
        }

    $displayGrade = $Candidate.ScidPairGrade

    if ($Candidate.ScidValidationReference -and
        $Candidate.ScidValidationReference.Independent) {

        $displayGrade =
            "CROSS-FEED $($Candidate.ScidPairGrade)"
    }
    else {
        if ($Candidate.ScidPairGrade -eq "STRONG") {
            $displayGrade = "MANAGED CONSISTENT"
        }
        else {
            $displayGrade =
                "MANAGED $($Candidate.ScidPairGrade)"
        }
    }

    return (
        "$displayGrade | $reference | $coverage | $volume | $price | $aggregate")
}


function Get-ScidArchivePaths(
    $Candidate,
    [string]$DataFolder) {

    $bridgePaths =
        Get-BridgePaths $DataFolder

    $archiveRoot =
        $bridgePaths.Archive

    $sourceStem =
        [IO.Path]::GetFileNameWithoutExtension(
            $Candidate.SourceName)

    $baselineDirectory =
        Join-Path `
            (Join-Path $archiveRoot "Rithmic_Baselines") `
            $sourceStem

    $rollbackDirectory =
        Join-Path `
            (Join-Path $archiveRoot "Rollbacks") `
            $sourceStem

    return [pscustomobject]@{
        ArchiveRoot = $archiveRoot
        BaselineDirectory = $baselineDirectory
        BaselineArchive =
            Join-Path `
                $baselineDirectory `
                ($Candidate.TargetName + ".gz")
        RollbackDirectory = $rollbackDirectory
        RollbackArchive =
            Join-Path `
                $rollbackDirectory `
                ($Candidate.TargetName + ".gz")
    }
}

function Read-ScidArchiveMeta([string]$ArchivePath) {
    $metadataPath =
        $ArchivePath + ".meta"

    if (-not (
        Test-Path `
            -LiteralPath $ArchivePath `
            -PathType Leaf) -or
        -not (
        Test-Path `
            -LiteralPath $metadataPath `
            -PathType Leaf)) {

        return $null
    }

    try {
        $values = @{}

        foreach ($line in
            (Get-Content `
                -LiteralPath $metadataPath `
                -ErrorAction Stop)) {

            $separator =
                $line.IndexOf("=")

            if ($separator -le 0) {
                continue
            }

            $key =
                $line.Substring(0, $separator)

            $value =
                $line.Substring($separator + 1)

            $values[$key] = $value
        }

        if (-not $values.ContainsKey("original_bytes") -or
            -not $values.ContainsKey("records") -or
            -not $values.ContainsKey("first_datetime") -or
            -not $values.ContainsKey("last_datetime")) {

            return $null
        }

        return [pscustomobject]@{
            OriginalBytes =
                [long]$values["original_bytes"]
            Records =
                [long]$values["records"]
            FirstDateTime =
                [long]$values["first_datetime"]
            LastDateTime =
                [long]$values["last_datetime"]
            OriginalWriteTicks =
                if ($values.ContainsKey(
                    "original_write_ticks")) {
                    [long]$values[
                        "original_write_ticks"]
                }
                else {
                    0L
                }
            Sha256 =
                if ($values.ContainsKey("sha256")) {
                    [string]$values["sha256"]
                }
                else {
                    ""
                }
        }
    }
    catch {
        return $null
    }
}

function Get-AvailableFreeBytes([string]$Path) {
    try {
        $root =
            [IO.Path]::GetPathRoot(
                [IO.Path]::GetFullPath($Path))

        $drive =
            New-Object `
                System.IO.DriveInfo `
                -ArgumentList $root

        return [long]$drive.AvailableFreeSpace
    }
    catch {
        return -1L
    }
}

function Format-StorageBytes([long]$Bytes) {
    if ($Bytes -lt 0) {
        return "unknown"
    }

    if ($Bytes -ge 1TB) {
        return "{0:0.00} TB" -f
            ($Bytes / 1TB)
    }

    if ($Bytes -ge 1GB) {
        return "{0:0.00} GB" -f
            ($Bytes / 1GB)
    }

    return "{0:0} MB" -f
        ($Bytes / 1MB)
}


function Format-SignedStorageBytes([long]$Bytes) {
    if ($Bytes -eq 0) {
        return "0 MB"
    }

    $prefix = "+"
    if ($Bytes -lt 0) {
        $prefix = "-"
        $Bytes = [Math]::Abs($Bytes)
    }

    return $prefix + (Format-StorageBytes $Bytes)
}

function Get-StorageSnapshot([string]$DataFolder) {
    $bridgePaths =
        Get-BridgePaths $DataFolder

    $dataRoot =
        [IO.Path]::GetFullPath(
            $bridgePaths.Data).TrimEnd('\') + '\'

    $archiveRoot =
        [IO.Path]::GetFullPath(
            $bridgePaths.Archive).TrimEnd('\') + '\'

    $recoveryRoot =
        [IO.Path]::GetFullPath(
            $bridgePaths.Recovery).TrimEnd('\') + '\'

    $logRoot =
        [IO.Path]::GetFullPath(
            $bridgePaths.Logs).TrimEnd('\') + '\'

    $sourcePattern =
        [regex]'^(?<root>.+?)(?<month>[FGHJKMNQUVXZ])(?<year>\d{2})-(?<exchange>[A-Za-z0-9_]+)\.(?<extension>scid|dly)$'

    $rithmicPattern =
        [regex]'^(?<root>.+?)(?<month>[FGHJKMNQUVXZ])(?<year>\d)\.(?<exchange>[A-Za-z0-9_]+)\.(?<extension>scid|dly)$'

    $categories = @{
        Sources = [long[]]@(0L, 0L)
        Rithmic = [long[]]@(0L, 0L)
        Archive = [long[]]@(0L, 0L)
        Recovery = [long[]]@(0L, 0L)
        Logs = [long[]]@(0L, 0L)
        Other = [long[]]@(0L, 0L)
    }

    function Add-StorageFile(
        [System.IO.FileInfo]$File,
        [string]$Category) {

        $logical = [long]$File.Length
        $allocated = $logical

        try {
            $allocated =
                [long][SierraHistoryBridge.ScidBridge]::GetFileAllocatedBytes(
                    $File.FullName)
        }
        catch { }

        $values = $categories[$Category]
        $values[0] += $logical
        $values[1] += $allocated
    }

    foreach ($file in @(
        Get-ChildItem `
            -LiteralPath $bridgePaths.Data `
            -Recurse `
            -File `
            -ErrorAction SilentlyContinue)) {

        $full =
            [IO.Path]::GetFullPath(
                $file.FullName)

        if ($full.StartsWith(
                $archiveRoot,
                [StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith(
                $recoveryRoot,
                [StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith(
                $logRoot,
                [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        if ($file.DirectoryName -ieq $bridgePaths.Data -and
            $sourcePattern.IsMatch($file.Name)) {
            Add-StorageFile $file "Sources"
        }
        elseif ($file.DirectoryName -ieq $bridgePaths.Data -and
            $rithmicPattern.IsMatch($file.Name)) {
            Add-StorageFile $file "Rithmic"
        }
        else {
            Add-StorageFile $file "Other"
        }
    }

    foreach ($pair in @(
        [pscustomobject]@{ Path = $bridgePaths.Archive; Category = "Archive" },
        [pscustomobject]@{ Path = $bridgePaths.Recovery; Category = "Recovery" },
        [pscustomobject]@{ Path = $bridgePaths.Logs; Category = "Logs" }
    )) {
        if (-not (Test-Path -LiteralPath $pair.Path -PathType Container)) {
            continue
        }

        foreach ($file in @(
            Get-ChildItem `
                -LiteralPath $pair.Path `
                -Recurse `
                -File `
                -ErrorAction SilentlyContinue)) {

            Add-StorageFile $file $pair.Category
        }
    }

    $logicalTotal = 0L
    $allocatedTotal = 0L

    foreach ($name in $categories.Keys) {
        $logicalTotal += $categories[$name][0]
        $allocatedTotal += $categories[$name][1]
    }

    return [pscustomobject]@{
        SourcesLogical = $categories.Sources[0]
        SourcesDisk = $categories.Sources[1]
        RithmicLogical = $categories.Rithmic[0]
        RithmicDisk = $categories.Rithmic[1]
        ArchiveLogical = $categories.Archive[0]
        ArchiveDisk = $categories.Archive[1]
        RecoveryLogical = $categories.Recovery[0]
        RecoveryDisk = $categories.Recovery[1]
        LogsLogical = $categories.Logs[0]
        LogsDisk = $categories.Logs[1]
        OtherLogical = $categories.Other[0]
        OtherDisk = $categories.Other[1]
        TotalLogical = $logicalTotal
        TotalDisk = $allocatedTotal
        Free = Get-AvailableFreeBytes $DataFolder
        ArchivePath = $bridgePaths.Archive
        RecoveryPath = $bridgePaths.Recovery
        LogPath = $bridgePaths.Logs
    }
}

function Show-StorageSnapshot([string]$Label, $Snapshot) {
    Write-Host (
        "      {0}: Data {1} logical / {2} disk | free {3}" -f
        $Label,
        (Format-StorageBytes $Snapshot.TotalLogical),
        (Format-StorageBytes $Snapshot.TotalDisk),
        (Format-StorageBytes $Snapshot.Free))
}

function Show-StorageDelta($Before, $After) {
    Write-Host
    Write-Host "Storage usage (disk):"
    Write-Host (
        "  {0,-20} {1,12} {2,12} {3,12}" -f
        "Category", "Before", "Delta", "Total")

    foreach ($row in @(
        [pscustomobject]@{ Name = "SC Data sources"; Before = $Before.SourcesDisk; After = $After.SourcesDisk },
        [pscustomobject]@{ Name = "Rithmic targets"; Before = $Before.RithmicDisk; After = $After.RithmicDisk },
        [pscustomobject]@{ Name = "Bridge archive"; Before = $Before.ArchiveDisk; After = $After.ArchiveDisk },
        [pscustomobject]@{ Name = "Recovery staging"; Before = $Before.RecoveryDisk; After = $After.RecoveryDisk },
        [pscustomobject]@{ Name = "Logs"; Before = $Before.LogsDisk; After = $After.LogsDisk },
        [pscustomobject]@{ Name = "Other Data"; Before = $Before.OtherDisk; After = $After.OtherDisk },
        [pscustomobject]@{ Name = "Data folder"; Before = $Before.TotalDisk; After = $After.TotalDisk },
        [pscustomobject]@{ Name = "Free space"; Before = $Before.Free; After = $After.Free }
    )) {
        Write-Host (
            "  {0,-20} {1,12} {2,12} {3,12}" -f
            $row.Name,
            (Format-StorageBytes ([long]$row.Before)),
            (Format-SignedStorageBytes ([long]$row.After - [long]$row.Before)),
            (Format-StorageBytes ([long]$row.After)))
    }

    Write-Host (
        "  Logical Data total: {0} -> {1}" -f
        (Format-StorageBytes $Before.TotalLogical),
        (Format-StorageBytes $After.TotalLogical))
}

function Read-FileArchiveMeta([string]$ArchivePath) {
    $metadataPath = $ArchivePath + ".meta"

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        return $null
    }

    try {
        $values = @{}
        foreach ($line in Get-Content -LiteralPath $metadataPath -ErrorAction Stop) {
            $separator = $line.IndexOf("=")
            if ($separator -le 0) {
                continue
            }

            $key = $line.Substring(0, $separator)
            $value = $line.Substring($separator + 1)
            $values[$key] = $value
        }

        if (-not $values.ContainsKey("original_name") -or
            -not $values.ContainsKey("original_bytes") -or
            -not $values.ContainsKey("sha256")) {
            return $null
        }

        $writeTicks = 0L
        if ($values.ContainsKey("original_write_ticks")) {
            $writeTicks = [long]$values["original_write_ticks"]
        }

        return [pscustomobject]@{
            OriginalName = [string]$values["original_name"]
            OriginalBytes = [long]$values["original_bytes"]
            OriginalWriteTicks = $writeTicks
            Sha256 = [string]$values["sha256"]
        }
    }
    catch {
        return $null
    }
}

function Convert-OptionalDate([string]$Value, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParse(
        $Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AllowWhiteSpaces,
        [ref]$parsed)) {
        throw "$Label is not a valid date: $Value"
    }

    return $parsed.Date
}

function Get-ScDataSourceFiles([string]$DataFolder) {
    $sourcePattern =
        [regex]'^(?<root>.+?)(?<month>[FGHJKMNQUVXZ])(?<year>\d{2})-(?<exchange>[A-Za-z0-9_]+)\.(?<extension>scid|dly)$'

    $files = @()

    foreach ($file in @(
        Get-ChildItem `
            -LiteralPath $DataFolder `
            -File `
            -ErrorAction SilentlyContinue)) {

        $match = $sourcePattern.Match($file.Name)
        if (-not $match.Success) {
            continue
        }

        $yearText = $match.Groups["year"].Value
        $fullYear = Resolve-FullContractYear $yearText
        $monthCode = $match.Groups["month"].Value.ToUpperInvariant()

        $files += [pscustomobject]@{
            Path = $file.FullName
            Name = $file.Name
            Root = $match.Groups["root"].Value.ToUpperInvariant()
            Exchange = $match.Groups["exchange"].Value.ToUpperInvariant()
            MonthCode = $monthCode
            FullYear = $fullYear
            ContractMonth = Get-ContractMonth $fullYear $monthCode
            Extension = $match.Groups["extension"].Value.ToLowerInvariant()
            Length = [long]$file.Length
            LastWriteTimeUtc = $file.LastWriteTimeUtc
        }
    }

    return @($files | Sort-Object ContractMonth, Extension, Name)
}

function Get-SourceArchivePath($SourceFile, [string]$DataFolder) {
    $safeGroup =
        ($SourceFile.Root + "-" + $SourceFile.Exchange) -replace '[^A-Za-z0-9_.-]', '_'

    $bridgePaths =
        Get-BridgePaths $DataFolder

    $directory =
        Join-Path `
            (Join-Path `
                $bridgePaths.Archive `
                "SC_Data") `
            $safeGroup

    $directory =
        Join-Path $directory ([string]$SourceFile.FullYear)

    return Join-Path $directory ($SourceFile.Name + ".gz")
}

function Select-ArchiveSourceFiles(
    $SourceFiles,
    [datetime]$DefaultBefore,
    [string]$FromValue,
    [string]$ToValue,
    [int]$AgeDays,
    [bool]$ArchiveAll,
    [bool]$Ask) {

    $from = Convert-OptionalDate $FromValue "FromDate"
    $to = Convert-OptionalDate $ToValue "ToDate"
    $daysValue = $AgeDays
    $allValue = $ArchiveAll

    $explicit =
        $allValue -or
        $daysValue -gt 0 -or
        $from -or
        $to

    if ($Ask -and -not $explicit) {
        Write-Host
        Write-Host "Archive selection:"
        Write-Host (
            "  [Enter] contracts before {0:yyyy-MM} (default)" -f
            $DefaultBefore)
        Write-Host "  D       contract date range"
        Write-Host "  N       archive contract months older than N days"
        Write-Host "  A       all SC Data source files"

        $choice = (Read-Host "Selection").Trim().ToUpperInvariant()

        if ($choice -eq "D") {
            $from = Convert-OptionalDate (Read-Host "From contract date (optional, YYYY-MM-DD)") "FromDate"
            $to = Convert-OptionalDate (Read-Host "Through contract date (optional, YYYY-MM-DD)") "ToDate"
        }
        elseif ($choice -eq "N") {
            $rawDays = Read-Host "Archive contract months older than how many days"
            $daysValue = [int]$rawDays
            if ($daysValue -le 0) {
                throw "Days must be greater than zero."
            }
        }
        elseif ($choice -eq "A") {
            $allValue = $true
        }
        elseif ($choice -ne "") {
            throw "Unknown archive selection."
        }
    }

    $selection = @($SourceFiles)

    if (-not $allValue -and
        $daysValue -le 0 -and
        -not $from -and
        -not $to) {
        $selection =
            @($selection | Where-Object { $_.ContractMonth -lt $DefaultBefore })
    }

    if ($daysValue -gt 0) {
        $cutoff = (Get-Date).Date.AddDays(-$daysValue)
        $selection =
            @($selection | Where-Object { $_.ContractMonth -le $cutoff })
    }

    if ($from) {
        $selection =
            @($selection | Where-Object { $_.ContractMonth -ge $from })
    }

    if ($to) {
        $selection =
            @($selection | Where-Object { $_.ContractMonth -le $to })
    }

    return $selection
}

function Invoke-SourceArchiveManager(
    [string]$ResolvedDataFolder,
    [bool]$AskForFilter) {

    Set-Location `
        -LiteralPath $ResolvedDataFolder

    [Environment]::CurrentDirectory =
        $ResolvedDataFolder

    $window = Get-BridgeWindow
    $sourceFiles = Get-ScDataSourceFiles $ResolvedDataFolder

    if ($SelectedFile) {
        $selectedPath =
            [IO.Path]::GetFullPath(
                $SelectedFile.Trim().Trim('"'))

        $selection =
            @(
                $sourceFiles |
                Where-Object {
                    $_.Path.Equals(
                        $selectedPath,
                        [StringComparison]::OrdinalIgnoreCase)
                }
            )

        if ($selection.Count -eq 0) {
            throw (
                "The selected file is not an SC Data two-digit-year source " +
                "file in the configured Sierra Data folder.")
        }
    }
    else {
        $selection =
            Select-ArchiveSourceFiles `
                $sourceFiles `
                $window.Start `
                $FromDate `
                $ToDate `
                $Days `
                ([bool]$All) `
                $AskForFilter
    }

    if ($selection.Count -eq 0) {
        Write-Host
        Write-Host "No SC Data source files match the archive filter."
        return 0
    }

    if (-not (Wait-ForSierraChartClosed `
            "Archiving SC Data source files" `
            $AskForFilter)) {
        return 0
    }

    $logical =
        [long](($selection | Measure-Object -Property Length -Sum).Sum)

    $disk = 0L
    $contractCount =
        @($selection | Group-Object Root, Exchange, FullYear, MonthCode).Count

    $zeroVolumeFiles = 0
    $validationWarnings = 0

    foreach ($item in $selection) {
        try {
            $disk +=
                [long][SierraHistoryBridge.ScidBridge]::GetFileAllocatedBytes(
                    $item.Path)

            if ($item.Extension -eq "dly") {
                $dailyMeta =
                    [SierraHistoryBridge.DailyBridge]::GetMeta(
                        $item.Path)

                if ($dailyMeta.ZeroVolumeRecords -gt 0) {
                    $zeroVolumeFiles++
                }
            }
            else {
                [SierraHistoryBridge.ScidBridge]::GetMeta(
                    $item.Path) | Out-Null
            }
        }
        catch {
            $validationWarnings++
            Write-Host (
                "  SKIP {0} | validation warning: {1}" -f
                $item.Name,
                $_.Exception.Message) -ForegroundColor Yellow
        }
    }

    if ($validationWarnings -gt 0) {
        $selection =
            @(
                $selection |
                Where-Object {
                    try {
                        if ($_.Extension -eq "dly") {
                            [SierraHistoryBridge.DailyBridge]::GetMeta($_.Path) | Out-Null
                        }
                        else {
                            [SierraHistoryBridge.ScidBridge]::GetMeta($_.Path) | Out-Null
                        }
                        $true
                    }
                    catch {
                        $false
                    }
                }
            )
    }

    if ($selection.Count -eq 0) {
        Write-Host "No valid source files remain to archive."
        return 2
    }

    $logical =
        [long](($selection | Measure-Object -Property Length -Sum).Sum)

    $disk = 0L
    foreach ($item in $selection) {
        try {
            $disk +=
                [long][SierraHistoryBridge.ScidBridge]::GetFileAllocatedBytes(
                    $item.Path)
        }
        catch {
            $disk += [long]$item.Length
        }
    }

    $contractCount =
        @($selection | Group-Object Root, Exchange, FullYear, MonthCode).Count

    $firstMonth = ($selection | Sort-Object ContractMonth | Select-Object -First 1).ContractMonth
    $lastMonth = ($selection | Sort-Object ContractMonth | Select-Object -Last 1).ContractMonth

    Write-Host
    Write-Host "Archive plan:"
    Write-Host (
        "  {0} file(s) across {1} contract(s) | {2:yyyy-MM}..{3:yyyy-MM}" -f
        $selection.Count,
        $contractCount,
        $firstMonth,
        $lastMonth)
    Write-Host (
        "  Current usage: {0} logical / {1} disk" -f
        (Format-StorageBytes $logical),
        (Format-StorageBytes $disk))
    Write-Host "  Archives keep the exact original filename plus .gz and are verified before source deletion."

    if ($zeroVolumeFiles -gt 0) {
        Write-Host (
            "  Daily data note: {0} selected DLY file(s) contain zero-volume records; they will be preserved exactly." -f
            $zeroVolumeFiles) -ForegroundColor Yellow
    }

    if ($DryRun) {
        Write-Host "Dry run: no files were changed."
        return 0
    }

    if (-not $Yes) {
        $answer = Read-Host "Archive these SC Data files? [y/N]"
        if ($answer.Trim().ToLowerInvariant() -notin @("y", "yes")) {
            Write-Host "Archive canceled."
            return 0
        }
    }

    $before = Get-StorageSnapshot $ResolvedDataFolder
    $archived = 0
    $failed = 0
    $rawBytes = 0L
    $archiveBytes = 0L

    foreach ($item in $selection) {
        $archivePath = Get-SourceArchivePath $item $ResolvedDataFolder
        $status = "ARCHIVE $($item.Name)"

        try {
            [SierraHistoryBridge.ScidBridge]::UpdateStatusLine($status)

            if ($item.Extension -eq "scid") {
                $result =
                    [SierraHistoryBridge.ScidBridge]::ArchiveScidGzipVerified(
                        $item.Path,
                        $archivePath,
                        $true,
                        $false)
            }
            else {
                $result =
                    [SierraHistoryBridge.ScidBridge]::ArchiveFileGzipVerified(
                        $item.Path,
                        $archivePath,
                        $true,
                        $false)
            }

            $rawBytes += [long]$result.OriginalBytes
            $archiveBytes += [long]$result.ArchiveBytes
            $archived++

            [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                (
                    "{0} | OK | {1} -> {2}" -f
                    $status,
                    (Format-StorageBytes $result.OriginalBytes),
                    (Format-StorageBytes $result.ArchiveBytes)))
        }
        catch {
            $failed++
            [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                "$status | FAILED | $($_.Exception.Message)")
        }
    }

    $emptyDirectoriesRemoved =
        Invoke-BridgeDirectoryHousekeeping `
            $ResolvedDataFolder

    $after = Get-StorageSnapshot $ResolvedDataFolder

    Write-Host
    Write-Host (
        "Archive done: {0} archived | {1} failed | raw {2} -> archive {3} | {4} empty folder(s) removed" -f
        $archived,
        $failed,
        (Format-StorageBytes $rawBytes),
        (Format-StorageBytes $archiveBytes),
        $emptyDirectoriesRemoved)

    Show-StorageDelta $before $after

    if ($failed -gt 0) {
        return 2
    }

    return 0
}

function Get-BridgeProtectedRootForPath(
    [string]$Path,
    [string]$DataFolder) {

    $fullPath =
        [IO.Path]::GetFullPath(
            $Path).TrimEnd('\')

    $bridgePaths =
        Get-BridgePaths $DataFolder

    # Choose the most specific configured root. Archive/Recovery/Logs can
    # themselves live under Data, and pruning must stop at the configured
    # sub-root rather than climbing all the way to Data.
    $roots =
        @(
            $bridgePaths.Archive,
            $bridgePaths.Recovery,
            $bridgePaths.Logs,
            $bridgePaths.Data
        ) |
        ForEach-Object {
            [IO.Path]::GetFullPath(
                [string]$_).TrimEnd('\')
        } |
        Sort-Object {
            $_.Length
        } -Descending

    foreach ($root in $roots) {
        if ($fullPath.Equals(
                $root,
                [StringComparison]::OrdinalIgnoreCase) -or
            $fullPath.StartsWith(
                $root + '\',
                [StringComparison]::OrdinalIgnoreCase)) {

            return $root
        }
    }

    return $null
}

function Move-WorkingDirectoryOutsideTree(
    [string]$Directory,
    [string]$FallbackRoot) {

    if ([string]::IsNullOrWhiteSpace($Directory) -or
        [string]::IsNullOrWhiteSpace($FallbackRoot)) {
        return $false
    }

    $tree =
        [IO.Path]::GetFullPath(
            $Directory).TrimEnd('\')

    $fallback =
        [IO.Path]::GetFullPath(
            $FallbackRoot).TrimEnd('\')

    $mustMove = $false

    try {
        $location =
            Get-Location

        if ($location.Provider.Name -eq "FileSystem") {
            $providerPath =
                [IO.Path]::GetFullPath(
                    $location.ProviderPath).TrimEnd('\')

            if ($providerPath.Equals(
                    $tree,
                    [StringComparison]::OrdinalIgnoreCase) -or
                $providerPath.StartsWith(
                    $tree + '\',
                    [StringComparison]::OrdinalIgnoreCase)) {

                $mustMove = $true
            }
        }
    }
    catch { }

    try {
        $processDirectory =
            [IO.Path]::GetFullPath(
                [Environment]::CurrentDirectory).TrimEnd('\')

        if ($processDirectory.Equals(
                $tree,
                [StringComparison]::OrdinalIgnoreCase) -or
            $processDirectory.StartsWith(
                $tree + '\',
                [StringComparison]::OrdinalIgnoreCase)) {

            $mustMove = $true
        }
    }
    catch { }

    if (-not $mustMove) {
        return $false
    }

    # PowerShell's provider location and the Win32 process current directory
    # are related but are not guaranteed to remain synchronized. Set both.
    Set-Location `
        -LiteralPath $fallback `
        -ErrorAction Stop

    [Environment]::CurrentDirectory =
        $fallback

    return $true
}

function Remove-EmptyParentChain(
    [string]$StartDirectory,
    [string]$ProtectedRoot) {

    if ([string]::IsNullOrWhiteSpace($StartDirectory) -or
        [string]::IsNullOrWhiteSpace($ProtectedRoot)) {
        return 0
    }

    $current =
        [IO.Path]::GetFullPath(
            $StartDirectory).TrimEnd('\')

    $root =
        [IO.Path]::GetFullPath(
            $ProtectedRoot).TrimEnd('\')

    $removed = 0

    while (
        -not $current.Equals(
            $root,
            [StringComparison]::OrdinalIgnoreCase) -and
        $current.StartsWith(
            $root + '\',
            [StringComparison]::OrdinalIgnoreCase)) {

        if (-not (
            Test-Path `
                -LiteralPath $current `
                -PathType Container)) {

            $parent =
                Split-Path `
                    -Parent `
                    $current

            if ([string]::IsNullOrWhiteSpace($parent)) {
                break
            }

            $current =
                [IO.Path]::GetFullPath(
                    $parent).TrimEnd('\')

            continue
        }

        $remaining =
            @(
                Get-ChildItem `
                    -LiteralPath $current `
                    -Force `
                    -ErrorAction SilentlyContinue
            )

        if ($remaining.Count -gt 0) {
            break
        }

        try {
            [void](Move-WorkingDirectoryOutsideTree `
                $current `
                $root)
        }
        catch {
            Write-Host (
                "  CLEANUP WARNING: could not move working directory away from " +
                $current +
                " | " +
                $_.Exception.Message) `
                -ForegroundColor Yellow
        }

        $deleted = $false

        for ($attempt = 1;
            $attempt -le 5;
            $attempt++) {

            try {
                Remove-Item `
                    -LiteralPath $current `
                    -Force `
                    -ErrorAction Stop

                $deleted = $true
                $removed++
                break
            }
            catch {
                if ($attempt -lt 5) {
                    Start-Sleep `
                        -Milliseconds 100
                }
                else {
                    $queued =
                        Add-DeferredDirectoryCleanup `
                            $current `
                            $root

                    if ($queued) {
                        Write-Host (
                            "  CLEANUP DEFERRED: empty folder is still in use; " +
                            "it will be retried after this window closes: " +
                            $current) `
                            -ForegroundColor Yellow
                    }
                }
            }
        }

        if (-not $deleted) {
            break
        }

        $parent =
            Split-Path `
                -Parent `
                $current

        if ([string]::IsNullOrWhiteSpace($parent)) {
            break
        }

        $current =
            [IO.Path]::GetFullPath(
                $parent).TrimEnd('\')
    }

    return $removed
}

function Remove-BridgeOwnedFileAndPrune(
    [string]$Path,
    [string]$DataFolder,
    [switch]$IgnoreMissing) {

    $script:CleanupDataFolder =
        $DataFolder

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Bridge-owned file path is empty."
    }

    $fullPath =
        [IO.Path]::GetFullPath(
            $Path)

    $protectedRoot =
        Get-BridgeProtectedRootForPath `
            $fullPath `
            $DataFolder

    if (-not $protectedRoot) {
        throw (
            "Refusing bridge cleanup outside configured storage roots: " +
            $fullPath)
    }

    if (-not (
        Test-Path `
            -LiteralPath $fullPath `
            -PathType Leaf)) {

        if ($IgnoreMissing) {
            # The paired file may already have been removed. Still prune from
            # its expected parent in case it was the last item there.
            $parent =
                Split-Path `
                    -Parent `
                    $fullPath

            return Remove-EmptyParentChain `
                $parent `
                $protectedRoot
        }

        throw "Bridge-owned file does not exist: $fullPath"
    }

    $parent =
        Split-Path `
            -Parent `
            $fullPath

    $deleted = $false

    for ($attempt = 1;
        $attempt -le 3;
        $attempt++) {

        try {
            Remove-Item `
                -LiteralPath $fullPath `
                -Force `
                -ErrorAction Stop

            $deleted = $true
            break
        }
        catch {
            if ($attempt -lt 3) {
                Start-Sleep `
                    -Milliseconds 50
            }
            else {
                throw
            }
        }
    }

    if (-not $deleted) {
        return 0
    }

    return Remove-EmptyParentChain `
        $parent `
        $protectedRoot
}

function Remove-EmptyBridgeDirectories(
    [string]$Root,
    [switch]$PreserveRoot) {

    if ([string]::IsNullOrWhiteSpace($Root) -or
        -not (
            Test-Path `
                -LiteralPath $Root `
                -PathType Container)) {

        return 0
    }

    $resolvedRoot =
        [IO.Path]::GetFullPath(
            $Root).TrimEnd('\')

    $removed = 0

    $directories =
        @(
            Get-ChildItem `
                -LiteralPath $resolvedRoot `
                -Directory `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue |
            Sort-Object {
                $_.FullName.Length
            } -Descending
        )

    foreach ($directory in $directories) {
        $removed +=
            Remove-EmptyParentChain `
                $directory.FullName `
                $resolvedRoot
    }

    if (-not $PreserveRoot) {
        try {
            $remaining =
                @(
                    Get-ChildItem `
                        -LiteralPath $resolvedRoot `
                        -Force `
                        -ErrorAction Stop
                )

            if ($remaining.Count -eq 0) {
                Remove-Item `
                    -LiteralPath $resolvedRoot `
                    -Force `
                    -ErrorAction Stop

                $removed++
            }
        }
        catch {
            Write-Host (
                "  CLEANUP WARNING: could not remove empty folder: " +
                $resolvedRoot +
                " | " +
                $_.Exception.Message) `
                -ForegroundColor Yellow
        }
    }

    return $removed
}

function Invoke-BridgeDirectoryHousekeeping(
    [string]$DataFolder) {

    $script:CleanupDataFolder =
        $DataFolder

    $bridgePaths =
        Get-BridgePaths $DataFolder

    $removed = 0

    foreach ($root in @(
        $bridgePaths.Archive,
        $bridgePaths.Recovery,
        $bridgePaths.Logs
    )) {
        $removed +=
            Remove-EmptyBridgeDirectories `
                $root `
                -PreserveRoot
    }

    return $removed
}


function Get-ArchivedSourceFiles([string]$DataFolder) {
    $bridgePaths =
        Get-BridgePaths $DataFolder

    $root =
        Join-Path `
            $bridgePaths.Archive `
            "SC_Data"

    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return @()
    }

    $sourcePattern =
        [regex]'^(?<root>.+?)(?<month>[FGHJKMNQUVXZ])(?<year>\d{2})-(?<exchange>[A-Za-z0-9_]+)\.(?<extension>scid|dly)$'

    $items = @()

    foreach ($archive in @(
        Get-ChildItem `
            -LiteralPath $root `
            -Recurse `
            -File `
            -Filter "*.gz" `
            -ErrorAction SilentlyContinue)) {

        $meta = Read-FileArchiveMeta $archive.FullName
        if (-not $meta) {
            Write-Host (
                "  ARCHIVE WARNING: metadata missing or invalid: {0}" -f
                $archive.FullName) -ForegroundColor Yellow
            continue
        }

        $match = $sourcePattern.Match($meta.OriginalName)
        if (-not $match.Success) {
            continue
        }

        $fullYear = Resolve-FullContractYear $match.Groups["year"].Value
        $monthCode = $match.Groups["month"].Value.ToUpperInvariant()

        $items += [pscustomobject]@{
            ArchivePath = $archive.FullName
            MetadataPath = $archive.FullName + ".meta"
            OriginalName = $meta.OriginalName
            Destination = Join-Path $DataFolder $meta.OriginalName
            OriginalBytes = [long]$meta.OriginalBytes
            OriginalWriteTicks = [long]$meta.OriginalWriteTicks
            Sha256 = $meta.Sha256
            Root = $match.Groups["root"].Value.ToUpperInvariant()
            Exchange = $match.Groups["exchange"].Value.ToUpperInvariant()
            FullYear = $fullYear
            MonthCode = $monthCode
            ContractMonth = Get-ContractMonth $fullYear $monthCode
            Extension = $match.Groups["extension"].Value.ToLowerInvariant()
            ArchiveBytes = [long]$archive.Length
        }
    }

    return @($items | Sort-Object ContractMonth, Extension, OriginalName)
}

function Select-RestoreArchives(
    $Archives,
    [string]$FromValue,
    [string]$ToValue,
    [int]$RecentDays,
    [bool]$RestoreAll,
    [bool]$Ask) {

    $from = Convert-OptionalDate $FromValue "FromDate"
    $to = Convert-OptionalDate $ToValue "ToDate"
    $daysValue = $RecentDays
    $allValue = $RestoreAll

    $explicit =
        $allValue -or
        $daysValue -gt 0 -or
        $from -or
        $to

    if ($Ask -and -not $explicit) {
        Write-Host
        Write-Host "Restore selection:"
        Write-Host "  [Enter] most recent archived contract (default)"
        Write-Host "  D       contract date range"
        Write-Host "  N       restore contract months from the last N days"
        Write-Host "  A       all archived SC Data files"

        $choice = (Read-Host "Selection").Trim().ToUpperInvariant()

        if ($choice -eq "D") {
            $from = Convert-OptionalDate (Read-Host "From contract date (optional, YYYY-MM-DD)") "FromDate"
            $to = Convert-OptionalDate (Read-Host "Through contract date (optional, YYYY-MM-DD)") "ToDate"
        }
        elseif ($choice -eq "N") {
            $rawDays = Read-Host "Restore contract months from the last how many days"
            $daysValue = [int]$rawDays
            if ($daysValue -le 0) {
                throw "Days must be greater than zero."
            }
        }
        elseif ($choice -eq "A") {
            $allValue = $true
        }
        elseif ($choice -ne "") {
            throw "Unknown restore selection."
        }
    }

    $selection = @($Archives)

    if (-not $allValue -and
        $daysValue -le 0 -and
        -not $from -and
        -not $to) {

        $latest =
            ($selection | Sort-Object ContractMonth -Descending | Select-Object -First 1).ContractMonth

        $selection =
            @($selection | Where-Object { $_.ContractMonth -eq $latest })
    }

    if ($daysValue -gt 0) {
        $cutoff = (Get-Date).Date.AddDays(-$daysValue)
        $selection =
            @($selection | Where-Object { $_.ContractMonth -ge $cutoff })
    }

    if ($from) {
        $selection =
            @($selection | Where-Object { $_.ContractMonth -ge $from })
    }

    if ($to) {
        $selection =
            @($selection | Where-Object { $_.ContractMonth -le $to })
    }

    return $selection
}

function Invoke-SourceRestoreManager(
    [string]$ResolvedDataFolder,
    [bool]$AskForFilter) {

    Set-Location `
        -LiteralPath $ResolvedDataFolder

    [Environment]::CurrentDirectory =
        $ResolvedDataFolder

    [void](Invoke-BridgeDirectoryHousekeeping $ResolvedDataFolder)

    $archives = Get-ArchivedSourceFiles $ResolvedDataFolder
    if ($archives.Count -eq 0) {
        Write-Host
        Write-Host "No archived SC Data source files are available."
        return 0
    }

    if ($SelectedFile) {
        $selectedPath =
            [IO.Path]::GetFullPath(
                $SelectedFile.Trim().Trim('"'))

        $selection =
            @(
                $archives |
                Where-Object {
                    $_.ArchivePath.Equals(
                        $selectedPath,
                        [StringComparison]::OrdinalIgnoreCase)
                }
            )

        if ($selection.Count -eq 0) {
            throw (
                "The selected file is not a recognized Sierra History Bridge " +
                "SC Data archive.")
        }
    }
    else {
        $selection =
            Select-RestoreArchives `
                $archives `
                $FromDate `
                $ToDate `
                $Days `
                ([bool]$All) `
                $AskForFilter
    }

    if ($selection.Count -eq 0) {
        Write-Host
        Write-Host "No archives match the restore filter."
        return 0
    }

    if (-not (Wait-ForSierraChartClosed `
            "Restoring archived SC Data files" `
            $AskForFilter)) {
        return 0
    }

    $rawBytes =
        [long](($selection | Measure-Object -Property OriginalBytes -Sum).Sum)
    $compressedBytes =
        [long](($selection | Measure-Object -Property ArchiveBytes -Sum).Sum)

    $firstMonth = ($selection | Sort-Object ContractMonth | Select-Object -First 1).ContractMonth
    $lastMonth = ($selection | Sort-Object ContractMonth | Select-Object -Last 1).ContractMonth

    Write-Host
    Write-Host "Restore plan:"
    Write-Host (
        "  {0} file(s) | {1:yyyy-MM}..{2:yyyy-MM}" -f
        $selection.Count,
        $firstMonth,
        $lastMonth)
    Write-Host (
        "  Archive {0} -> original files {1} logical" -f
        (Format-StorageBytes $compressedBytes),
        (Format-StorageBytes $rawBytes))
    Write-Host "  Successfully restored archives are removed so the same data is not stored twice."

    $conflicts = @()
    $alreadyPresent = @()
    $pending = @()

    foreach ($item in $selection) {
        if (Test-Path -LiteralPath $item.Destination -PathType Leaf) {
            try {
                $existingHash =
                    [SierraHistoryBridge.ScidBridge]::HashFileSha256(
                        $item.Destination)

                if ($existingHash -ieq $item.Sha256 -and
                    (Get-Item -LiteralPath $item.Destination).Length -eq $item.OriginalBytes) {
                    $alreadyPresent += $item
                }
                else {
                    $conflicts += $item
                }
            }
            catch {
                $conflicts += $item
            }
        }
        else {
            $pending += $item
        }
    }

    $replaceConflicts = $false
    if ($conflicts.Count -gt 0) {
        Write-Host (
            "  Conflict: {0} destination file(s) already exist with different data." -f
            $conflicts.Count) -ForegroundColor Yellow

        if (-not $Yes) {
            $answer = Read-Host "Preserve the existing files in a conflict archive and replace them? [y/N]"
            $replaceConflicts =
                $answer.Trim().ToLowerInvariant() -in @("y", "yes")
        }
    }

    if ($DryRun) {
        Write-Host "Dry run: no files were changed."
        return 0
    }

    if (-not $Yes -and
        $pending.Count -gt 0) {
        $answer = Read-Host "Restore the selected archives? [y/N]"
        if ($answer.Trim().ToLowerInvariant() -notin @("y", "yes")) {
            Write-Host "Restore canceled."
            return 0
        }
    }

    $before = Get-StorageSnapshot $ResolvedDataFolder
    $restored = 0
    $deduplicated = 0
    $skippedConflicts = 0
    $failed = 0
    $conflictStamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")

    foreach ($item in $alreadyPresent) {
        try {
            [void](Remove-BridgeOwnedFileAndPrune `
                $item.ArchivePath `
                $ResolvedDataFolder)

            [void](Remove-BridgeOwnedFileAndPrune `
                $item.MetadataPath `
                $ResolvedDataFolder `
                -IgnoreMissing)

            $deduplicated++
        }
        catch {
            $failed++
        }
    }

    foreach ($item in $conflicts) {
        if (-not $replaceConflicts) {
            $skippedConflicts++
            continue
        }

        try {
            $bridgePaths =
                Get-BridgePaths $ResolvedDataFolder

            $conflictDirectory =
                Join-Path `
                    (Join-Path `
                        $bridgePaths.Archive `
                        "Restore_Conflicts") `
                    $conflictStamp

            $conflictArchive =
                Join-Path $conflictDirectory ($item.OriginalName + ".gz")

            if ($item.Extension -eq "scid") {
                [SierraHistoryBridge.ScidBridge]::ArchiveScidGzipVerified(
                    $item.Destination,
                    $conflictArchive,
                    $true,
                    $false) | Out-Null
            }
            else {
                [SierraHistoryBridge.ScidBridge]::ArchiveFileGzipVerified(
                    $item.Destination,
                    $conflictArchive,
                    $true,
                    $false) | Out-Null
            }

            $pending += $item
        }
        catch {
            $failed++
            Write-Host (
                "  FAILED conflict preservation: {0} | {1}" -f
                $item.OriginalName,
                $_.Exception.Message) -ForegroundColor Red
        }
    }

    foreach ($item in $pending) {
        $status = "RESTORE $($item.OriginalName)"
        try {
            [SierraHistoryBridge.ScidBridge]::UpdateStatusLine($status)

            $isScid = $item.Extension -eq "scid"
            $result =
                [SierraHistoryBridge.ScidBridge]::RestoreFileGzipVerified(
                    $item.ArchivePath,
                    $item.Destination,
                    [long]$item.OriginalBytes,
                    [string]$item.Sha256,
                    [long]$item.OriginalWriteTicks,
                    [bool]$isScid,
                    $false)

            [void](Remove-BridgeOwnedFileAndPrune `
                $item.ArchivePath `
                $ResolvedDataFolder)

            [void](Remove-BridgeOwnedFileAndPrune `
                $item.MetadataPath `
                $ResolvedDataFolder `
                -IgnoreMissing)

            $restored++

            [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                "$status | OK | $(Format-StorageBytes $result.RestoredBytes)")
        }
        catch {
            $failed++
            [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                "$status | FAILED | $($_.Exception.Message)")
        }
    }

    $emptyDirectoriesRemoved =
        Invoke-BridgeDirectoryHousekeeping `
            $ResolvedDataFolder

    $after = Get-StorageSnapshot $ResolvedDataFolder

    Write-Host
    Write-Host (
        "Restore done: {0} restored | {1} already present/deduplicated | {2} conflict(s) skipped | {3} failed | {4} empty folder(s) removed" -f
        $restored,
        $deduplicated,
        $skippedConflicts,
        $failed,
        $emptyDirectoriesRemoved)

    Show-StorageDelta $before $after

    if ($failed -gt 0) {
        return 2
    }

    return 0
}

function Get-RithmicBaselineArchives(
    [string]$DataFolder) {

    $bridgePaths =
        Get-BridgePaths $DataFolder

    $root =
        Join-Path `
            $bridgePaths.Archive `
            "Rithmic_Baselines"

    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return @()
    }

    $items = @()

    foreach ($archive in @(
        Get-ChildItem `
            -LiteralPath $root `
            -Recurse `
            -File `
            -Filter "*.scid.gz" `
            -ErrorAction SilentlyContinue)) {

        $meta =
            Read-ScidArchiveMeta `
                $archive.FullName

        if (-not $meta) {
            continue
        }

        $sourceStem =
            $archive.Directory.Name

        $sourceName =
            $sourceStem + ".scid"

        $targetName =
            $archive.Name.Substring(
                0,
                $archive.Name.Length - 3)

        $sourceMatch =
            [regex]::Match(
                $sourceName,
                '^(?<root>.+?)(?<month>[FGHJKMNQUVXZ])(?<year>\d{2})-(?<exchange>[A-Za-z0-9_]+)\.scid$')

        if (-not $sourceMatch.Success) {
            continue
        }

        $group =
            "$($sourceMatch.Groups["root"].Value.ToUpperInvariant())|" +
            "$($sourceMatch.Groups["exchange"].Value.ToUpperInvariant())"

        $items +=
            [pscustomobject]@{
                ArchivePath = $archive.FullName
                MetadataPath = $archive.FullName + ".meta"
                SourceName = $sourceName
                SourcePath =
                    Join-Path `
                        $DataFolder `
                        $sourceName
                TargetName = $targetName
                TargetPath =
                    Join-Path `
                        $DataFolder `
                        $targetName
                Group = $group
                ArchiveBytes = [long]$archive.Length
                Meta = $meta
            }
    }

    return @(
        $items |
        Sort-Object SourceName, TargetName
    )
}

function Invoke-VerifiedBaselineCleanup(
    [string]$ResolvedDataFolder,
    [bool]$Ask) {

    $baselines =
        Get-RithmicBaselineArchives `
            $ResolvedDataFolder

    if ($baselines.Count -eq 0) {
        Write-Host
        Write-Host "No Rithmic baseline archives are present."
        [void](Invoke-BridgeDirectoryHousekeeping $ResolvedDataFolder)
        return 0
    }

    $totalBytes =
        [long]((
            $baselines |
            Measure-Object `
                -Property ArchiveBytes `
                -Sum).Sum)

    Write-Host
    Write-Host (
        "Rithmic baselines: {0} file(s) | {1} on disk" -f
        $baselines.Count,
        (Format-StorageBytes $totalBytes))

    Write-Host (
        "These are the original independent Rithmic files kept only for cross-feed validation.")

    if ($Ask -and -not $Yes) {
        Write-Host (
            "Removing them requires one final full source-vs-baseline validation.")
        Write-Host (
            "Only STRONG, fully covered, current pairs are deleted; anything uncertain is kept.")

        $answer =
            Read-Host "Verify and remove eligible Rithmic baselines? [y/N]"

        if ($answer.Trim().ToLowerInvariant() -notin @("y", "yes")) {
            return 0
        }
    }

    $config =
        Read-JsonFile `
            $ConfigPath

    $scales =
        Get-ScaleTable `
            $config

    $removed = 0
    $kept = 0
    $failed = 0
    $reclaimed = 0L

    foreach ($item in $baselines) {
        $status =
            "VERIFY BASELINE $($item.SourceName) <-> $($item.TargetName)"

        try {
            if (-not (
                Test-Path `
                    -LiteralPath $item.SourcePath `
                    -PathType Leaf) -or
                -not (
                Test-Path `
                    -LiteralPath $item.TargetPath `
                    -PathType Leaf)) {

                $kept++
                Write-Host (
                    "  KEEP {0} | source or target is not currently available" -f
                    $item.TargetName) `
                    -ForegroundColor Yellow
                continue
            }

            if (-not $scales.ContainsKey($item.Group)) {
                $kept++
                Write-Host (
                    "  KEEP {0} | no verified price scale for {1}" -f
                    $item.TargetName,
                    $item.Group) `
                    -ForegroundColor Yellow
                continue
            }

            $sourceMeta =
                [SierraHistoryBridge.ScidBridge]::GetMeta(
                    $item.SourcePath)

            $targetMeta =
                [SierraHistoryBridge.ScidBridge]::GetMeta(
                    $item.TargetPath)

            if ($sourceMeta.FirstDateTime -gt
                    [long]$item.Meta.FirstDateTime -or
                $sourceMeta.LastDateTime -lt
                    [long]$item.Meta.LastDateTime) {

                $kept++
                Write-Host (
                    "  KEEP {0} | SC Data does not fully cover the original Rithmic baseline" -f
                    $item.TargetName) `
                    -ForegroundColor Yellow
                continue
            }

            $currentPair =
                [SierraHistoryBridge.ScidBridge]::QuickConvertedPairMatches(
                    $item.SourcePath,
                    $item.TargetPath,
                    [double]$scales[$item.Group])

            if (-not $currentPair) {
                $kept++
                Write-Host (
                    "  KEEP {0} | current Rithmic-named target does not match the converted SC Data source" -f
                    $item.TargetName) `
                    -ForegroundColor Yellow
                continue
            }

            [SierraHistoryBridge.ScidBridge]::UpdateStatusLine(
                $status)

            $validation =
                [SierraHistoryBridge.ScidBridge]::ValidatePairGzipTarget(
                    $item.SourcePath,
                    $item.ArchivePath,
                    [long]$item.Meta.OriginalBytes,
                    [long]$item.Meta.FirstDateTime,
                    [long]$item.Meta.LastDateTime,
                    [double]$scales[$item.Group],
                    $status)

            $grade =
                Get-ScidPairGrade `
                    $validation

            $safeToRemove =
                $grade -eq "STRONG" -and
                $validation.SourceOutOfOrderRecords -eq 0 -and
                $validation.TargetOutOfOrderRecords -eq 0

            if (-not $safeToRemove) {
                [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                    "$status | KEEP | $grade")

                $kept++
                continue
            }

            if ($DryRun) {
                [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                    "$status | VERIFIED | dry run")

                $kept++
                continue
            }

            $bytes =
                [long](
                    Get-Item `
                        -LiteralPath $item.ArchivePath).Length

            [void](Remove-BridgeOwnedFileAndPrune `
                $item.ArchivePath `
                $ResolvedDataFolder)

            [void](Remove-BridgeOwnedFileAndPrune `
                $item.MetadataPath `
                $ResolvedDataFolder `
                -IgnoreMissing)

            $removed++
            $reclaimed += $bytes

            [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                (
                    "$status | VERIFIED + REMOVED | reclaimed {0}" -f
                    (Format-StorageBytes $bytes)))
        }
        catch {
            $failed++

            try {
                [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                    "$status | FAILED | $($_.Exception.Message)")
            }
            catch { }
        }
    }

    $emptyDirectories =
        Invoke-BridgeDirectoryHousekeeping `
            $ResolvedDataFolder

    Write-Host
    Write-Host (
        "Baseline cleanup: {0} removed | {1} kept | {2} failed | reclaimed {3} | {4} empty folder(s) removed" -f
        $removed,
        $kept,
        $failed,
        (Format-StorageBytes $reclaimed),
        $emptyDirectories)

    if ($failed -gt 0) {
        return 2
    }

    return 0
}

function Invoke-StorageReport([string]$ResolvedDataFolder) {
    $snapshot = Get-StorageSnapshot $ResolvedDataFolder

    Write-Host
    Write-Host "Storage usage:"
    Write-Host (
        "  {0,-20} {1,14} {2,14}" -f
        "Category", "Logical", "On disk")

    foreach ($row in @(
        [pscustomobject]@{ Name = "SC Data sources"; Logical = $snapshot.SourcesLogical; Disk = $snapshot.SourcesDisk },
        [pscustomobject]@{ Name = "Rithmic targets"; Logical = $snapshot.RithmicLogical; Disk = $snapshot.RithmicDisk },
        [pscustomobject]@{ Name = "Bridge archive"; Logical = $snapshot.ArchiveLogical; Disk = $snapshot.ArchiveDisk },
        [pscustomobject]@{ Name = "Recovery staging"; Logical = $snapshot.RecoveryLogical; Disk = $snapshot.RecoveryDisk },
        [pscustomobject]@{ Name = "Logs"; Logical = $snapshot.LogsLogical; Disk = $snapshot.LogsDisk },
        [pscustomobject]@{ Name = "Other Data"; Logical = $snapshot.OtherLogical; Disk = $snapshot.OtherDisk },
        [pscustomobject]@{ Name = "Data folder"; Logical = $snapshot.TotalLogical; Disk = $snapshot.TotalDisk }
    )) {
        Write-Host (
            "  {0,-20} {1,14} {2,14}" -f
            $row.Name,
            (Format-StorageBytes ([long]$row.Logical)),
            (Format-StorageBytes ([long]$row.Disk)))
    }

    Write-Host (
        "  {0,-20} {1,14}" -f
        "Free space",
        (Format-StorageBytes $snapshot.Free))

    Write-Host
    Write-Host "Configured storage:"
    Write-Host "  Archive:  $($snapshot.ArchivePath)"
    Write-Host "  Recovery: $($snapshot.RecoveryPath)"
    Write-Host "  Logs:     $($snapshot.LogPath)"

    $baselines =
        Get-RithmicBaselineArchives `
            $ResolvedDataFolder

    if ($baselines.Count -gt 0) {
        $baselineBytes =
            [long]((
                $baselines |
                Measure-Object `
                    -Property ArchiveBytes `
                    -Sum).Sum)

        Write-Host
        Write-Host (
            "Rithmic baselines: {0} file(s) | {1} on disk" -f
            $baselines.Count,
            (Format-StorageBytes $baselineBytes))

        if ($Interactive) {
            $answer =
                Read-Host "Verify and remove eligible baselines now? [y/N]"

            if ($answer.Trim().ToLowerInvariant() -in @("y", "yes")) {
                return Invoke-VerifiedBaselineCleanup `
                    $ResolvedDataFolder `
                    $false
            }
        }
    }

    return 0
}

function Invoke-BridgeStorageCleanup([string]$DataFolder) {
    $bridgePaths =
        Get-BridgePaths $DataFolder

    $backupDirectory =
        $bridgePaths.Recovery

    $archiveRoot =
        $bridgePaths.Archive

    $reclaimed = 0L
    $pruned = 0
    $compressed = 0
    $staleTemps = 0
    $warnings = 0

    # Reclaim abandoned full-size conversion files first. This can provide
    # enough headroom to compress legacy backups on a nearly full drive.
    $cutoff =
        (Get-Date).ToUniversalTime().AddHours(-1)

    foreach ($pattern in
        @("*.scbridge.tmp",
          "*.dailybridge.tmp")) {

        foreach ($temp in
            @(
                Get-ChildItem `
                    -LiteralPath $DataFolder `
                    -File `
                    -Filter $pattern `
                    -ErrorAction SilentlyContinue
            )) {

            if ($temp.LastWriteTimeUtc -ge $cutoff) {
                continue
            }

            try {
                $reclaimed +=
                    [long]$temp.Length

                Remove-Item `
                    -LiteralPath $temp.FullName `
                    -Force

                $staleTemps++
            }
            catch {
                $warnings++
            }
        }
    }

    if (Test-Path `
        -LiteralPath $archiveRoot `
        -PathType Container) {

        foreach ($temp in
            @(
                Get-ChildItem `
                    -LiteralPath $archiveRoot `
                    -Recurse `
                    -File `
                    -Filter "*.tmp" `
                    -ErrorAction SilentlyContinue
            )) {

            if ($temp.LastWriteTimeUtc -ge $cutoff) {
                continue
            }

            try {
                $reclaimed +=
                    [long]$temp.Length

                [void](Remove-BridgeOwnedFileAndPrune `
                    $temp.FullName `
                    $DataFolder)

                $staleTemps++
            }
            catch {
                $warnings++
            }
        }
    }

    if (Test-Path `
        -LiteralPath $backupDirectory `
        -PathType Container) {

        $backupFiles =
            @(
                Get-ChildItem `
                    -LiteralPath $backupDirectory `
                    -File `
                    -ErrorAction SilentlyContinue
            )

        foreach ($backup in $backupFiles) {
            if ($backup.Name -like
                "*.rithmic-baseline.bak") {

                # Baselines are handled when their source contract is scanned
                # so they can be placed under the correct two-digit contract
                # archive and immediately reused for preflight validation.
                continue
            }

            if ($backup.Name -like "*.scid.bak") {
                $targetName =
                    $backup.Name.Substring(
                        0,
                        $backup.Name.Length - 4)

                # A legacy .scid.bak can be the original Rithmic file from an
                # older bridge build. Preserve it instead of assuming it is a
                # disposable rolling backup.
                $legacyStamp =
                    $backup.LastWriteTimeUtc.ToString(
                        "yyyyMMdd-HHmmss")

                $legacyDirectory =
                    Join-Path `
                        (Join-Path $archiveRoot "Legacy_Backups") `
                        $legacyStamp

                $archivePath =
                    Join-Path `
                        $legacyDirectory `
                        ($targetName + ".gz")

                try {
                    $result =
                        [SierraHistoryBridge.ScidBridge]::ArchiveScidGzipVerified(
                            $backup.FullName,
                            $archivePath,
                            $true,
                            $false)

                    $reclaimed +=
                        [long]$result.OriginalBytes -
                        [long]$result.ArchiveBytes

                    $compressed++
                }
                catch {
                    $warnings++
                }

                continue
            }

            if ($backup.Name -like "*.dly.bak") {
                $targetName =
                    $backup.Name.Substring(
                        0,
                        $backup.Name.Length - 4)

                $legacyStamp =
                    $backup.LastWriteTimeUtc.ToString(
                        "yyyyMMdd-HHmmss")

                $legacyDirectory =
                    Join-Path `
                        (Join-Path $archiveRoot "Legacy_Backups") `
                        $legacyStamp

                $archivePath =
                    Join-Path `
                        $legacyDirectory `
                        ($targetName + ".gz")

                try {
                    $result =
                        [SierraHistoryBridge.ScidBridge]::ArchiveFileGzipVerified(
                            $backup.FullName,
                            $archivePath,
                            $true,
                            $false)

                    $reclaimed +=
                        [long]$result.OriginalBytes -
                        [long]$result.ArchiveBytes

                    $compressed++
                }
                catch {
                    $warnings++
                }

                continue
            }
        }
    }

    $emptyDirectories =
        Invoke-BridgeDirectoryHousekeeping `
            $DataFolder

    return [pscustomobject]@{
        ReclaimedBytes = $reclaimed
        PrunedBackups = $pruned
        CompressedBackups = $compressed
        StaleTemps = $staleTemps
        EmptyDirectories = $emptyDirectories
        Warnings = $warnings
    }
}



function Finalize-ScidBackupStorage(
    $Candidate,
    [string]$DataFolder,
    [string]$BackupDirectory) {

    $saved = 0L
    $archived = $false
    $pruned = $false
    $warning = $null

    try {
        if ($Candidate.CreateRithmicBaseline) {
            $rawBaseline =
                Join-Path `
                    $BackupDirectory `
                    (
                        $Candidate.SourceName +
                        "__" +
                        $Candidate.TargetName +
                        ".rithmic-baseline.bak")

            if (Test-Path `
                -LiteralPath $rawBaseline `
                -PathType Leaf) {

                $paths =
                    Get-ScidArchivePaths `
                        $Candidate `
                        $DataFolder

                [SierraHistoryBridge.ScidBridge]::UpdateStatusLine(
                    (
                        "ARCHIVE {0} | original Rithmic baseline" -f
                        $Candidate.TargetName))

                $result =
                    [SierraHistoryBridge.ScidBridge]::ArchiveScidGzipVerified(
                        $rawBaseline,
                        $paths.BaselineArchive,
                        $true,
                        $false)

                $saved =
                    [long]$result.OriginalBytes -
                    [long]$result.ArchiveBytes

                $archived = $true
            }
        }
        else {
            $rawBackup =
                Join-Path `
                    $BackupDirectory `
                    ($Candidate.TargetName + ".bak")

            if (Test-Path `
                -LiteralPath $rawBackup `
                -PathType Leaf) {

                if ($Candidate.LiveScidUpdate -or
                    $Candidate.ScidTemporaryMerge) {

                    $paths =
                        Get-ScidArchivePaths `
                            $Candidate `
                            $DataFolder

                    [SierraHistoryBridge.ScidBridge]::UpdateStatusLine(
                        (
                            "ARCHIVE {0} | rollback" -f
                            $Candidate.TargetName))

                    $result =
                        [SierraHistoryBridge.ScidBridge]::ArchiveScidGzipVerified(
                            $rawBackup,
                            $paths.RollbackArchive,
                            $true,
                            $true)

                    $saved =
                        [long]$result.OriginalBytes -
                        [long]$result.ArchiveBytes

                    $archived = $true
                }
                else {
                    $saved =
                        [long](
                            Get-Item `
                                -LiteralPath $rawBackup).Length

                    [void](Remove-BridgeOwnedFileAndPrune `
                        $rawBackup `
                        $DataFolder)

                    $pruned = $true
                }
            }
        }
    }
    catch {
        $warning =
            $_.Exception.Message
    }

    return [pscustomobject]@{
        SavedBytes = $saved
        Archived = $archived
        Pruned = $pruned
        Warning = $warning
    }
}

function Finalize-DailyBackupStorage(
    $Candidate,
    [string]$DataFolder,
    [string]$BackupDirectory) {

    $backup =
        Join-Path `
            $BackupDirectory `
            ($Candidate.DailyTargetName + ".bak")

    if (-not (
        Test-Path `
            -LiteralPath $backup `
            -PathType Leaf)) {

        return 0L
    }

    $bytes =
        [long](
            Get-Item `
                -LiteralPath $backup).Length

    [void](Remove-BridgeOwnedFileAndPrune `
        $backup `
        $DataFolder)

    return $bytes
}

function Get-ScidValidationReference($Candidate, [string]$DataFolder) {
    if (-not $Candidate.TargetStatus.Exists -or
        $Candidate.TargetStatus.Kind -ne "data") {

        return [pscustomobject]@{
            Path = $null
            Kind = "none"
            Independent = $false
            CreateBaseline = $false
            Compressed = $false
            ArchiveMeta = $null
        }
    }

    $bridgePaths =
        Get-BridgePaths $DataFolder

    $backupDirectory =
        $bridgePaths.Recovery

    $paths =
        Get-ScidArchivePaths `
            $Candidate `
            $DataFolder

    $archiveMeta =
        Read-ScidArchiveMeta `
            $paths.BaselineArchive

    if ($archiveMeta) {
        return [pscustomobject]@{
            Path = $paths.BaselineArchive
            Kind = "archived Rithmic baseline"
            Independent = $true
            CreateBaseline = $false
            Compressed = $true
            ArchiveMeta = $archiveMeta
        }
    }

    $baselineName =
        $Candidate.SourceName +
        "__" +
        $Candidate.TargetName +
        ".rithmic-baseline.bak"

    $baselinePath =
        Join-Path `
            $backupDirectory `
            $baselineName

    $legacyBaselinePath =
        Join-Path `
            $backupDirectory `
            ($Candidate.TargetName +
                ".rithmic-baseline.bak")

    $rawBaselinePath =
        if (Test-Path `
            -LiteralPath $baselinePath `
            -PathType Leaf) {

            $baselinePath
        }
        elseif (Test-Path `
            -LiteralPath $legacyBaselinePath `
            -PathType Leaf) {

            $legacyBaselinePath
        }
        else {
            $null
        }

    if ($rawBaselinePath) {
        try {
            $status =
                "ARCHIVE {0} | Rithmic baseline" -f
                $Candidate.TargetName

            [SierraHistoryBridge.ScidBridge]::UpdateStatusLine(
                $status)

            $archiveResult =
                [SierraHistoryBridge.ScidBridge]::ArchiveScidGzipVerified(
                    $rawBaselinePath,
                    $paths.BaselineArchive,
                    $true,
                    $false)

            [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                (
                    "{0} | {1:N0} MB -> {2:N0} MB" -f
                    $status,
                    ($archiveResult.OriginalBytes / 1MB),
                    ($archiveResult.ArchiveBytes / 1MB)))

            $archiveMeta =
                Read-ScidArchiveMeta `
                    $paths.BaselineArchive

            if ($archiveMeta) {
                return [pscustomobject]@{
                    Path = $paths.BaselineArchive
                    Kind = "archived Rithmic baseline"
                    Independent = $true
                    CreateBaseline = $false
                    Compressed = $true
                    ArchiveMeta = $archiveMeta
                }
            }
        }
        catch {
            [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                (
                    "ARCHIVE {0} | WARNING | {1}" -f
                    $Candidate.TargetName,
                    $_.Exception.Message))
        }

        if (Test-Path `
            -LiteralPath $rawBaselinePath `
            -PathType Leaf) {

            return [pscustomobject]@{
                Path = $rawBaselinePath
                Kind = "Rithmic baseline"
                Independent = $true
                CreateBaseline = $false
                Compressed = $false
                ArchiveMeta = $null
            }
        }
    }

    $previouslyManaged = $false

    if ($Candidate.PreviousState) {
        $managedProperty =
            $Candidate.PreviousState.PSObject.Properties[
                "scid_managed_by_bridge"]

        if ($managedProperty) {
            $previouslyManaged =
                [bool]$managedProperty.Value
        }
        elseif ($Candidate.PreviousState.source_signature) {
            $previouslyManaged = $true
        }
    }

    if (-not $previouslyManaged) {
        return [pscustomobject]@{
            Path = $Candidate.Target
            Kind = "current Rithmic target"
            Independent = $true
            CreateBaseline = $true
            Compressed = $false
            ArchiveMeta = $null
        }
    }

    return [pscustomobject]@{
        Path = $Candidate.Target
        Kind = "managed target"
        Independent = $false
        CreateBaseline = $false
        Compressed = $false
        ArchiveMeta = $null
    }
}


function Test-ScidPreflightSnapshotCurrent($Candidate) {
    try {
        $sourceMeta =
            [SierraHistoryBridge.ScidBridge]::GetMeta(
                $Candidate.Source)

        $sourceWriteTicks =
            (Get-Item `
                -LiteralPath $Candidate.Source).LastWriteTimeUtc.Ticks

        if ($Candidate.ScidValidation) {
            $reference =
                $Candidate.ScidValidationReference

            if ($reference.Compressed) {
                $archiveMeta =
                    Read-ScidArchiveMeta `
                        $reference.Path

                if (-not $archiveMeta) {
                    return $false
                }

                $archiveWriteTicks =
                    (Get-Item `
                        -LiteralPath $reference.Path).LastWriteTimeUtc.Ticks

                return (
                    $sourceMeta.Records -eq
                        $Candidate.ScidValidation.SourceRecords -and
                    $sourceMeta.FirstDateTime -eq
                        $Candidate.ScidValidation.SourceFirstDateTime -and
                    $sourceMeta.LastDateTime -eq
                        $Candidate.ScidValidation.SourceLastDateTime -and
                    $sourceMeta.Length -eq
                        $Candidate.ScidValidation.SourceLength -and
                    $sourceWriteTicks -eq
                        $Candidate.ScidValidation.SourceWriteTimeUtcTicks -and
                    $archiveMeta.Records -eq
                        $Candidate.ScidValidation.TargetRecords -and
                    $archiveMeta.FirstDateTime -eq
                        $Candidate.ScidValidation.TargetFirstDateTime -and
                    $archiveMeta.LastDateTime -eq
                        $Candidate.ScidValidation.TargetLastDateTime -and
                    $archiveMeta.OriginalBytes -eq
                        $Candidate.ScidValidation.TargetLength -and
                    $archiveWriteTicks -eq
                        $Candidate.ScidValidation.TargetWriteTimeUtcTicks)
            }

            $referencePath =
                $reference.Path

            $targetMeta =
                [SierraHistoryBridge.ScidBridge]::GetMeta(
                    $referencePath)

            $targetWriteTicks =
                (Get-Item `
                    -LiteralPath $referencePath).LastWriteTimeUtc.Ticks

            return (
                $sourceMeta.Records -eq
                    $Candidate.ScidValidation.SourceRecords -and
                $sourceMeta.FirstDateTime -eq
                    $Candidate.ScidValidation.SourceFirstDateTime -and
                $sourceMeta.LastDateTime -eq
                    $Candidate.ScidValidation.SourceLastDateTime -and
                $sourceMeta.Length -eq
                    $Candidate.ScidValidation.SourceLength -and
                $sourceWriteTicks -eq
                    $Candidate.ScidValidation.SourceWriteTimeUtcTicks -and
                $targetMeta.Records -eq
                    $Candidate.ScidValidation.TargetRecords -and
                $targetMeta.FirstDateTime -eq
                    $Candidate.ScidValidation.TargetFirstDateTime -and
                $targetMeta.LastDateTime -eq
                    $Candidate.ScidValidation.TargetLastDateTime -and
                $targetMeta.Length -eq
                    $Candidate.ScidValidation.TargetLength -and
                $targetWriteTicks -eq
                    $Candidate.ScidValidation.TargetWriteTimeUtcTicks)
        }

        if ($Candidate.ScidFileValidation) {
            return (
                $sourceMeta.Records -eq
                    $Candidate.ScidFileValidation.Records -and
                $sourceMeta.FirstDateTime -eq
                    $Candidate.ScidFileValidation.FirstDateTime -and
                $sourceMeta.LastDateTime -eq
                    $Candidate.ScidFileValidation.LastDateTime -and
                $sourceMeta.Length -eq
                    $Candidate.ScidFileValidation.Length -and
                $sourceWriteTicks -eq
                    $Candidate.ScidFileValidation.WriteTimeUtcTicks)
        }

        return $true
    }
    catch {
        return $false
    }
}


function Get-CandidateSourceDisplay($Candidate) {
    if ($Candidate.HasScid -and $Candidate.SourceName) {
        return Get-CompactName $Candidate.SourceName
    }

    if ($Candidate.DailySourceName) {
        return Get-CompactName $Candidate.DailySourceName
    }

    return $Candidate.ContractKey
}

function Get-CandidateTargetDisplay($Candidate) {
    if ($Candidate.HasScid -and $Candidate.TargetName) {
        return Get-CompactName $Candidate.TargetName
    }

    if ($Candidate.DailyTargetName) {
        return Get-CompactName $Candidate.DailyTargetName
    }

    return $Candidate.ContractKey
}

function Get-ScaleTable($Config) {
    $table = @{}

    if ($Config.proven_scales) {
        foreach ($property in $Config.proven_scales.PSObject.Properties) {
            try {
                $table[$property.Name] = [double]$property.Value
            }
            catch { }
        }
    }

    return $table
}

function Get-StateTable($State) {
    $table = @{}

    if ($State.sources) {
        foreach ($property in $State.sources.PSObject.Properties) {
            $table[$property.Name] = $property.Value
        }
    }

    return $table
}

function Get-TargetStatus([string]$TargetPath) {
    if (-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) {
        return [pscustomobject]@{
            Exists = $false
            Kind = "missing"
            Records = 0
            Length = 0
            FirstDateTime = 0
            LastDateTime = 0
        }
    }

    try {
        $meta = [SierraHistoryBridge.ScidBridge]::GetMeta($TargetPath)

        return [pscustomobject]@{
            Exists = $true
            Kind = $(if ($meta.Records -eq 0) { "placeholder" } else { "data" })
            Records = [long]$meta.Records
            Length = [long]$meta.Length
            FirstDateTime = [long]$meta.FirstDateTime
            LastDateTime = [long]$meta.LastDateTime
        }
    }
    catch {
        return [pscustomobject]@{
            Exists = $true
            Kind = "invalid"
            Records = 0
            Length = [long](Get-Item -LiteralPath $TargetPath).Length
            FirstDateTime = 0
            LastDateTime = 0
        }
    }
}

function Test-LegacyScidSignatureEquivalent(
    [string]$LegacySignature,
    [string]$CurrentSignature) {

    if ([string]::IsNullOrWhiteSpace($LegacySignature) -or
        [string]::IsNullOrWhiteSpace($CurrentSignature) -or
        -not $CurrentSignature.StartsWith("v2|")) {
        return $false
    }

    $oldParts = $LegacySignature.Split('|')
    $newParts = $CurrentSignature.Split('|')

    if ($oldParts.Count -ne 3 -or
        $newParts.Count -lt 5) {
        return $false
    }

    try {
        # Legacy: size | LastWriteTimeUtc.Ticks | last SCID timestamp
        # v2:     v2 | size | first timestamp | last timestamp | quick hash
        return (
            [long]$oldParts[0] -eq [long]$newParts[1] -and
            [long]$oldParts[2] -eq [long]$newParts[3])
    }
    catch {
        return $false
    }
}

function Update-ScidStateMetadata(
    $StateEntry,
    $Candidate,
    [string]$SourceSignature,
    $TargetStatus) {

    if ($null -eq $StateEntry -or
        $StateEntry -is [string]) {

        $StateEntry = [pscustomobject]@{}
    }

    $StateEntry |
        Add-Member `
            -NotePropertyName source_signature `
            -NotePropertyValue $SourceSignature `
            -Force

    $StateEntry |
        Add-Member `
            -NotePropertyName target_path `
            -NotePropertyValue $Candidate.Target `
            -Force

    $StateEntry |
        Add-Member `
            -NotePropertyName minimum_target_records `
            -NotePropertyValue ([long]$TargetStatus.Records) `
            -Force

    $StateEntry |
        Add-Member `
            -NotePropertyName target_first_datetime `
            -NotePropertyValue ([long]$TargetStatus.FirstDateTime) `
            -Force

    $StateEntry |
        Add-Member `
            -NotePropertyName minimum_target_last_datetime `
            -NotePropertyValue ([long]$TargetStatus.LastDateTime) `
            -Force

    $StateEntry |
        Add-Member `
            -NotePropertyName scid_managed_by_bridge `
            -NotePropertyValue $true `
            -Force

    return $StateEntry
}

function Test-ProcessedTargetStillValid(
    $StateEntry,
    [string]$SourceSignature,
    $TargetStatus) {

    # Older pre-release state stored only the source signature. It cannot prove
    # that the target file still contains the converted output, so reprocess it.
    if ($StateEntry -is [string]) {
        return $false
    }

    if ($null -eq $StateEntry -or
        -not $StateEntry.source_signature) {
        return $false
    }

    $savedSignature =
        [string]$StateEntry.source_signature

    if ($savedSignature -ne $SourceSignature -and
        -not (Test-LegacyScidSignatureEquivalent `
            $savedSignature `
            $SourceSignature)) {
        return $false
    }

    if (-not $TargetStatus.Exists -or
        $TargetStatus.Kind -ne "data") {
        return $false
    }

    try {
        $minimumRecords = [long]$StateEntry.minimum_target_records
        $expectedFirst = [long]$StateEntry.target_first_datetime
        $minimumLast = [long]$StateEntry.minimum_target_last_datetime
    }
    catch {
        return $false
    }

    if ($minimumRecords -le 0) {
        return $false
    }

    # Current-contract Rithmic files can legitimately grow after conversion,
    # so records/last timestamp are minimums rather than exact values.
    if ($TargetStatus.Records -lt $minimumRecords) {
        return $false
    }

    if ($expectedFirst -ne 0 -and
        $TargetStatus.FirstDateTime -ne $expectedFirst) {
        return $false
    }

    if ($minimumLast -ne 0 -and
        $TargetStatus.LastDateTime -lt $minimumLast) {
        return $false
    }

    return $true
}


function Get-DailyTargetStatus([string]$TargetPath) {
    if (-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) {
        return [pscustomobject]@{
            Exists = $false
            Kind = "missing"
            Records = 0
            Length = 0
            FirstDateTicks = 0
            LastDateTicks = 0
        }
    }

    try {
        $meta = [SierraHistoryBridge.DailyBridge]::GetMeta($TargetPath)

        return [pscustomobject]@{
            Exists = $true
            Kind = $(if ($meta.Records -eq 0) { "empty" } else { "data" })
            Records = [long]$meta.Records
            Length = [long]$meta.Length
            FirstDateTicks = [long]$meta.FirstDateTicks
            LastDateTicks = [long]$meta.LastDateTicks
        }
    }
    catch {
        return [pscustomobject]@{
            Exists = $true
            Kind = "invalid"
            Records = 0
            Length = [long](Get-Item -LiteralPath $TargetPath).Length
            FirstDateTicks = 0
            LastDateTicks = 0
        }
    }
}

function Get-DailySourceSignature([string]$SourcePath) {
    $hash =
        Get-FileHash `
            -LiteralPath $SourcePath `
            -Algorithm SHA256

    return "sha256:$($hash.Hash.ToLowerInvariant())"
}

function Update-DailyStateMetadata(
    $StateEntry,
    $Candidate,
    [string]$SourceSignature,
    $TargetStatus) {

    if ($null -eq $StateEntry) {
        $StateEntry = [pscustomobject]@{
            source_signature = $null
            target_path = $Candidate.Target
            minimum_target_records = 0
            target_first_datetime = 0
            minimum_target_last_datetime = 0
        }
    }

    $StateEntry |
        Add-Member `
            -NotePropertyName daily_source_signature `
            -NotePropertyValue $SourceSignature `
            -Force

    $StateEntry |
        Add-Member `
            -NotePropertyName daily_target_path `
            -NotePropertyValue $Candidate.DailyTarget `
            -Force

    $StateEntry |
        Add-Member `
            -NotePropertyName daily_minimum_target_records `
            -NotePropertyValue ([long]$TargetStatus.Records) `
            -Force

    $StateEntry |
        Add-Member `
            -NotePropertyName daily_target_first_date_ticks `
            -NotePropertyValue ([long]$TargetStatus.FirstDateTicks) `
            -Force

    $StateEntry |
        Add-Member `
            -NotePropertyName daily_minimum_target_last_date_ticks `
            -NotePropertyValue ([long]$TargetStatus.LastDateTicks) `
            -Force

    return $StateEntry
}

function Test-ProcessedDailyTargetStillValid(
    $StateEntry,
    [string]$SourceSignature,
    $TargetStatus) {

    if ($null -eq $StateEntry -or
        -not $StateEntry.daily_source_signature -or
        [string]$StateEntry.daily_source_signature -ne $SourceSignature) {
        return $false
    }

    if (-not $TargetStatus.Exists -or
        $TargetStatus.Kind -ne "data") {
        return $false
    }

    try {
        $minimumRecords = [long]$StateEntry.daily_minimum_target_records
        $expectedFirst = [long]$StateEntry.daily_target_first_date_ticks
        $minimumLast = [long]$StateEntry.daily_minimum_target_last_date_ticks
    }
    catch {
        return $false
    }

    if ($minimumRecords -le 0 -or
        $TargetStatus.Records -lt $minimumRecords) {
        return $false
    }

    if ($expectedFirst -ne 0 -and
        $TargetStatus.FirstDateTicks -ne $expectedFirst) {
        return $false
    }

    if ($minimumLast -ne 0 -and
        $TargetStatus.LastDateTicks -lt $minimumLast) {
        return $false
    }

    return $true
}

function Convert-HashtableToObject([hashtable]$Table) {
    $ordered = [ordered]@{}
    foreach ($key in ($Table.Keys | Sort-Object)) {
        $ordered[$key] = $Table[$key]
    }
    return [pscustomobject]$ordered
}

function Invoke-SierraHistoryBridge {
    Show-Banner

    if (-not (Test-Path -LiteralPath $ConverterSource)) {
        throw "ScidBridge.cs was not found next to SierraHistoryBridge.ps1."
    }

    Write-Host -NoNewline "[1/4] Converter  "
    Add-Type -Path $ConverterSource
    Write-Host "OK"

    $resolvedDataFolder = Get-SierraDataFolder $DataFolder
    Write-Host "[2/4] Data       $resolvedDataFolder"

    $storageBeforeRun =
        Get-StorageSnapshot `
            $resolvedDataFolder

    $storageCleanup =
        Invoke-BridgeStorageCleanup `
            $resolvedDataFolder

    $freeAfterCleanup =
        Get-AvailableFreeBytes `
            $resolvedDataFolder

    $storageAfterCleanup =
        Get-StorageSnapshot `
            $resolvedDataFolder

    Write-Host (
        "      Storage: {0} free | Data {1} logical / {2} disk | reclaimed {3} | pruned {4} backup(s) | compressed {5} backup(s) | removed {6} stale temp(s) / {7} empty folder(s)" -f
        (Format-StorageBytes $freeAfterCleanup),
        (Format-StorageBytes $storageAfterCleanup.TotalLogical),
        (Format-StorageBytes $storageAfterCleanup.TotalDisk),
        (Format-StorageBytes $storageCleanup.ReclaimedBytes),
        $storageCleanup.PrunedBackups,
        $storageCleanup.CompressedBackups,
        $storageCleanup.StaleTemps,
        $storageCleanup.EmptyDirectories)

    if ($storageCleanup.Warnings -gt 0) {
        Write-Host (
            "      Storage warnings: {0} item(s) left untouched" -f
            $storageCleanup.Warnings) `
            -ForegroundColor Yellow
    }

    $config = Read-JsonFile $ConfigPath
    $config | Add-Member -NotePropertyName default_data_folder -NotePropertyValue $resolvedDataFolder -Force

    if (-not $config.proven_scales) {
        $config | Add-Member -NotePropertyName proven_scales -NotePropertyValue ([pscustomobject]@{}) -Force
    }

    Write-Host -NoNewline "[3/4] Scan       "

    $sourcePattern =
        [regex]'^(?<root>.+?)(?<month>[FGHJKMNQUVXZ])(?<year>\d{2})-(?<exchange>[A-Za-z0-9_]+)\.(?<extension>scid|dly)$'

    $contracts = @{}

    function Get-OrCreateContractCandidate(
        [string]$Root,
        [string]$Month,
        [string]$Year,
        [string]$Exchange) {

        $contractKey =
            "{0}|{1}|{2}|{3}" -f
            $Root.ToUpperInvariant(),
            $Month.ToUpperInvariant(),
            $Year,
            $Exchange.ToUpperInvariant()

        if ($contracts.ContainsKey($contractKey)) {
            return $contracts[$contractKey]
        }

        $rithmicYear =
            $Year.Substring($Year.Length - 1, 1)

        $targetBase =
            "$Root$($Month.ToUpperInvariant())$rithmicYear.$($Exchange.ToUpperInvariant())"

        $candidate = [pscustomobject]@{
            ContractKey = $contractKey
            Root = $Root
            MonthCode = $Month.ToUpperInvariant()
            FullYear = Resolve-FullContractYear $Year
            ContractMonth =
                Get-ContractMonth `
                    (Resolve-FullContractYear $Year) `
                    $Month.ToUpperInvariant()
            Group =
                "$($Root.ToUpperInvariant())|$($Exchange.ToUpperInvariant())"

            HasScid = $false
            Source = $null
            SourceName = $null
            Target =
                Join-Path $resolvedDataFolder "$targetBase.scid"
            TargetName = "$targetBase.scid"
            Records = 0
            First = 0
            Last = 0
            Size = 0
            ModifiedTicks = 0

            DailyAvailable = $false
            DailyError = $null
            DailySource = $null
            DailySourceName = $null
            DailyTarget =
                Join-Path $resolvedDataFolder "$targetBase.dly"
            DailyTargetName = "$targetBase.dly"
            DailyRecords = 0
            DailyFirstDateTicks = 0
            DailyLastDateTicks = 0
            DailySize = 0
            DailyModifiedTicks = 0
            DailyZeroVolumeRecords = 0
            DailyPositiveVolumeRecords = 0
            DailyPlaceholder = $false

            StateKey = $null
        }

        $contracts[$contractKey] = $candidate
        return $candidate
    }

    Get-ChildItem -LiteralPath $resolvedDataFolder -File |
        Where-Object {
            $_.Extension -ieq ".scid" -or
            $_.Extension -ieq ".dly"
        } |
        Sort-Object Name |
        ForEach-Object {
            $file = $_
            $match = $sourcePattern.Match($file.Name)

            if (-not $match.Success) {
                return
            }

            $root = $match.Groups["root"].Value
            $month =
                $match.Groups["month"].Value.ToUpperInvariant()
            $year = $match.Groups["year"].Value
            $exchange =
                $match.Groups["exchange"].Value.ToUpperInvariant()
            $extension =
                $match.Groups["extension"].Value.ToLowerInvariant()

            $candidate =
                Get-OrCreateContractCandidate `
                    $root `
                    $month `
                    $year `
                    $exchange

            if ($extension -eq "scid") {
                try {
                    $meta =
                        [SierraHistoryBridge.ScidBridge]::GetMeta(
                            $file.FullName)

                    if ($meta.Records -gt 0) {
                        $candidate.HasScid = $true
                        $candidate.Source = $file.FullName
                        $candidate.SourceName = $file.Name
                        $candidate.Records = [long]$meta.Records
                        $candidate.First = [long]$meta.FirstDateTime
                        $candidate.Last = [long]$meta.LastDateTime
                        $candidate.Size = [long]$file.Length
                        $candidate.ModifiedTicks =
                            [long]$file.LastWriteTimeUtc.Ticks
                    }
                }
                catch {
                    Write-Host (
                        "      SCID WARNING: {0}: {1}" -f
                        $file.Name,
                        $_.Exception.Message) -ForegroundColor Yellow
                }
            }
            elseif ($extension -eq "dly") {
                try {
                    $dailyMeta =
                        [SierraHistoryBridge.DailyBridge]::GetMeta(
                            $file.FullName)

                    $candidate.DailySource =
                        $file.FullName
                    $candidate.DailySourceName =
                        $file.Name
                    $candidate.DailySize =
                        [long]$file.Length
                    $candidate.DailyModifiedTicks =
                        [long]$file.LastWriteTimeUtc.Ticks
                    $candidate.DailyZeroVolumeRecords =
                        [long]$dailyMeta.ZeroVolumeRecords
                    $candidate.DailyPositiveVolumeRecords =
                        [long]$dailyMeta.PositiveVolumeRecords

                    if ($dailyMeta.Records -gt 0) {
                        $candidate.DailyAvailable = $true
                        $candidate.DailyError = $null
                        $candidate.DailyRecords =
                            [long]$dailyMeta.Records
                        $candidate.DailyFirstDateTicks =
                            [long]$dailyMeta.FirstDateTicks
                        $candidate.DailyLastDateTicks =
                            [long]$dailyMeta.LastDateTicks
                    }
                    else {
                        $candidate.DailyPlaceholder = $true
                    }
                }
                catch {
                    $candidate.DailyError =
                        $_.Exception.Message
                    $candidate.DailySource =
                        $file.FullName
                    $candidate.DailySourceName =
                        $file.Name
                }
            }
        }

    $candidates =
        @(
            $contracts.Values |
            Where-Object {
                $_.HasScid -or
                $_.DailyAvailable -or
                $_.DailyError
            }
        )

    foreach ($candidate in $candidates) {
        $candidate.StateKey =
            if ($candidate.HasScid) {
                $candidate.Source
            }
            elseif ($candidate.DailySource) {
                $candidate.DailySource
            }
            else {
                $candidate.ContractKey
            }
    }

    if ($candidates.Count -eq 0) {
        throw (
            "No matching SC Data futures files were found. Expected names " +
            "such as NQU26-CME.scid or NQU26-CME.dly.")
    }

    # Rithmic's one-digit year repeats every ten years. Sierra Chart also
    # limits single-digit-year Continuous Futures Contract charts to five
    # years. Treat Rithmic-named files as a rolling history set, not
    # as the long-term source archive.
    $bridgeWindow = Get-BridgeWindow
    $windowStart = $bridgeWindow.Start
    $windowEnd = $bridgeWindow.End

    $archiveCandidates = $candidates

    $candidates =
        $archiveCandidates |
        Where-Object {
            Test-ContractInRithmicWindow `
                $_.ContractMonth `
                $windowStart `
                $windowEnd
        }

    $archiveOnly =
        $archiveCandidates |
        Where-Object {
            -not (
                Test-ContractInRithmicWindow `
                    $_.ContractMonth `
                    $windowStart `
                    $windowEnd)
        }

    $olderSourceContracts =
        @(
            $archiveOnly |
            Where-Object { $_.ContractMonth -lt $windowStart }
        )

    $futureSourceContracts =
        @(
            $archiveOnly |
            Where-Object { $_.ContractMonth -gt $windowEnd }
        )

    # The selected window is deliberately much shorter than the ten-year
    # Rithmic filename alias cycle. If an unusual source set still maps more
    # than one eligible contract to the same target, newest eligible wins and
    # the older candidate remains available only under its SC Data filename.
    $superseded = @()
    $selected = @()

    foreach ($targetGroup in ($candidates | Group-Object TargetName)) {
        $winner =
            $targetGroup.Group |
            Sort-Object ContractMonth -Descending |
            Select-Object -First 1

        $selected += $winner

        if ($targetGroup.Count -gt 1) {
            $superseded +=
                $targetGroup.Group |
                Where-Object { $_.ContractKey -ne $winner.ContractKey }
        }
    }

    $candidates = $selected | Sort-Object ContractMonth, SourceName

    if ($candidates.Count -eq 0) {
        throw (
            "No SC Data contracts fall inside the current Rithmic history window " +
            "($($windowStart.ToString('yyyy-MM')) through $($windowEnd.ToString('yyyy-MM'))).")
    }

    $eligibleScid =
        @($candidates | Where-Object { $_.HasScid }).Count
    $eligibleDaily =
        @($candidates | Where-Object { $_.DailyAvailable }).Count

    Write-Host (
        "{0} eligible contracts | {1} SCID | {2} DLY | {3} older source | {4} future source | window {5}..{6}" -f
        $candidates.Count,
        $eligibleScid,
        $eligibleDaily,
        $olderSourceContracts.Count,
        $futureSourceContracts.Count,
        $windowStart.ToString("yyyy-MM"),
        $windowEnd.ToString("yyyy-MM"))

    Write-Host (
        "      Policy: 5y Sierra history + 3mo rollover buffer + 6mo forward buffer")

    $dailyZeroVolumeSources =
        @(
            $archiveCandidates |
            Where-Object {
                $_.DailyZeroVolumeRecords -gt 0
            }
        )

    $dailyPlaceholderSources =
        @(
            $archiveCandidates |
            Where-Object {
                $_.DailyPlaceholder
            }
        )

    if ($dailyZeroVolumeSources.Count -gt 0 -or
        $dailyPlaceholderSources.Count -gt 0) {

        Write-Host (
            "      Daily source quality: {0} file(s) with zero-volume rows | {1} header-only file(s) | preserved as supplied" -f
            $dailyZeroVolumeSources.Count,
            $dailyPlaceholderSources.Count) `
            -ForegroundColor Yellow
    }

    if ($superseded.Count -gt 0) {
        Write-Host (
            "      {0} eligible source(s) were superseded by newer contract mappings." -f
            $superseded.Count) -ForegroundColor Yellow
    }

    $dailySourceErrors =
        $candidates |
        Where-Object { $_.DailyError }

    foreach ($dailySourceError in $dailySourceErrors) {
        Write-Host (
            "      DLY WARNING: {0}: {1}" -f
            $dailySourceError.DailySourceName,
            $dailySourceError.DailyError) -ForegroundColor Yellow
    }

    Write-Host "      Scale verification:"

    $scales = Get-ScaleTable $config

    foreach ($group in ($candidates.Group | Sort-Object -Unique)) {
        $verified = $false

        $scidPair =
            $candidates |
            Where-Object {
                $_.Group -eq $group -and
                $_.HasScid -and
                (Test-Path -LiteralPath $_.Target -PathType Leaf)
            } |
            Sort-Object Last -Descending |
            Select-Object -First 1

        if ($scidPair) {
            try {
                $inference =
                    [SierraHistoryBridge.ScidBridge]::InferScale(
                        $scidPair.Source,
                        $scidPair.Target)

                $scales[$group] =
                    [double]$inference.Factor
                $verified = $true

                Write-Host (
                    "        {0,-12} x{1:g} verified SCID | {2} <-> {3} | {4} samples" -f
                    $group,
                    $inference.Factor,
                    $scidPair.SourceName,
                    $scidPair.TargetName,
                    $inference.Samples)
            }
            catch {
                # Try Historical Daily below.
            }
        }

        if (-not $verified) {
            $dailyPair =
                $candidates |
                Where-Object {
                    $_.Group -eq $group -and
                    $_.DailyAvailable -and
                    (Test-Path `
                        -LiteralPath $_.DailyTarget `
                        -PathType Leaf)
                } |
                Sort-Object DailyLastDateTicks -Descending |
                Select-Object -First 1

            if ($dailyPair) {
                try {
                    $inference =
                        [SierraHistoryBridge.DailyBridge]::InferScale(
                            $dailyPair.DailySource,
                            $dailyPair.DailyTarget)

                    $scales[$group] =
                        [double]$inference.Factor
                    $verified = $true

                    Write-Host (
                        "        {0,-12} x{1:g} verified DLY  | {2} <-> {3} | {4} samples" -f
                        $group,
                        $inference.Factor,
                        $dailyPair.DailySourceName,
                        $dailyPair.DailyTargetName,
                        $inference.Samples)
                }
                catch {
                    # Use a previously proven scale if one exists.
                }
            }
        }

        if (-not $verified) {
            if ($scales.ContainsKey($group)) {
                Write-Host (
                    "        {0,-12} x{1:g} saved" -f
                    $group,
                    $scales[$group]) -ForegroundColor Yellow
            }
            else {
                Write-Host (
                    "        {0,-12} UNVERIFIED - no overlapping SCID/DLY target" -f
                    $group) -ForegroundColor Yellow
            }
        }
    }

    $config.proven_scales = Convert-HashtableToObject $scales
    Save-JsonFile $ConfigPath $config

    $state = Read-JsonFile $StatePath
    $stateTable = Get-StateTable $state
    $stateDirty = $false

    # Remove obsolete DLY-only state entries once the same contract has a
    # SCID-owned state entry. Current state keeps SCID and DLY metadata together.
    foreach ($stateKey in @($stateTable.Keys)) {
        if (-not $stateKey.EndsWith(
            ".dly",
            [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $scidKey = [IO.Path]::ChangeExtension($stateKey, ".scid")
        if ($stateTable.ContainsKey($scidKey)) {
            $stateTable.Remove($stateKey)
            $stateDirty = $true
        }
    }

    # Surface sources which were present on a previous run but disappeared.
    # This is informational and never deletes or rewrites the surviving target.
    foreach ($candidate in $candidates) {
        if (-not $candidate.HasScid) {
            continue
        }

        if (-not $stateTable.ContainsKey($candidate.Source)) {
            continue
        }

        $previousEntry = $stateTable[$candidate.Source]
        if ($null -eq $previousEntry -or $previousEntry -is [string]) {
            continue
        }

        if ($previousEntry.daily_source_signature -and
            -not $candidate.DailyAvailable) {

            $expectedDaily = [IO.Path]::ChangeExtension($candidate.Source, ".dly")

            Write-Host (
                "      SOURCE CHANGE: {0} was present on a previous run but is missing now; existing target left unchanged." -f
                [IO.Path]::GetFileName($expectedDaily)) -ForegroundColor Yellow
        }
    }

    # Build a retirement plan for bridge-managed Rithmic files whose
    # SC Data contract has moved outside the managed history window.
    # Only modern state entries with verifiable target metadata are eligible.
    # Never retire a target path currently required by an eligible contract.
    $eligibleTargetPaths = @{}
    foreach ($candidate in $candidates) {
        $eligibleTargetPaths[$candidate.Target.ToLowerInvariant()] = $true
    }

    $retire = @()

    foreach ($sourcePath in @($stateTable.Keys)) {
        $entry = $stateTable[$sourcePath]

        if ($entry -is [string] -or
            $null -eq $entry -or
            -not $entry.target_path) {
            continue
        }

        $sourceName = [IO.Path]::GetFileName([string]$sourcePath)
        $match = $sourcePattern.Match($sourceName)

        if (-not $match.Success) {
            continue
        }

        $fullYear = Resolve-FullContractYear $match.Groups["year"].Value
        $monthCode = $match.Groups["month"].Value.ToUpperInvariant()
        $contractMonth = Get-ContractMonth $fullYear $monthCode

        if (Test-ContractInRithmicWindow $contractMonth $windowStart $windowEnd) {
            continue
        }

        $targetPath = [string]$entry.target_path
        $targetKey = $targetPath.ToLowerInvariant()

        if ($eligibleTargetPaths.ContainsKey($targetKey)) {
            # The one-digit target name has been legitimately reused by a
            # newer eligible decade. Drop only the stale state entry.
            $retire += [pscustomobject]@{
                Source = $sourcePath
                SourceName = $sourceName
                Target = $targetPath
                TargetName = [IO.Path]::GetFileName($targetPath)
                RemoveTarget = $false
                DailyTarget =
                    if ($entry.daily_target_path) {
                        [string]$entry.daily_target_path
                    }
                    else {
                        [IO.Path]::ChangeExtension($targetPath, ".dly")
                    }
                RemoveDailyTarget = $false
                Reason = "target name is used by a newer eligible contract"
            }
            continue
        }

        $targetStatus = Get-TargetStatus $targetPath

        if (-not $targetStatus.Exists) {
            $dailyTargetPath =
                if ($entry.daily_target_path) {
                    [string]$entry.daily_target_path
                }
                else {
                    [IO.Path]::ChangeExtension($targetPath, ".dly")
                }

            $removeDaily = $false

            if ($entry.daily_minimum_target_records -and
                (Test-Path -LiteralPath $dailyTargetPath -PathType Leaf)) {

                $dailyStatus =
                    Get-DailyTargetStatus $dailyTargetPath

                $removeDaily =
                    $dailyStatus.Kind -eq "data" -and
                    $dailyStatus.Records -ge
                        [long]$entry.daily_minimum_target_records -and
                    (
                        -not $entry.daily_target_first_date_ticks -or
                        $dailyStatus.FirstDateTicks -eq
                            [long]$entry.daily_target_first_date_ticks
                    )
            }

            $retire += [pscustomobject]@{
                Source = $sourcePath
                SourceName = $sourceName
                Target = $targetPath
                TargetName = [IO.Path]::GetFileName($targetPath)
                RemoveTarget = $false
                DailyTarget = $dailyTargetPath
                RemoveDailyTarget = [bool]$removeDaily
                Reason = "managed intraday target already missing"
            }
            continue
        }

        # Retire only a target that still looks like the file recorded by the
        # bridge. If it has become unrecognizable, leave it alone and keep a
        # warning in the plan instead of deleting an unknown file.
        $safeToRemove =
            $targetStatus.Kind -eq "data" -and
            $entry.minimum_target_records -and
            $targetStatus.Records -ge [long]$entry.minimum_target_records -and
            (
                -not $entry.target_first_datetime -or
                $targetStatus.FirstDateTime -eq [long]$entry.target_first_datetime
            )

        $dailyTargetPath =
            if ($entry.daily_target_path) {
                [string]$entry.daily_target_path
            }
            else {
                [IO.Path]::ChangeExtension($targetPath, ".dly")
            }

        $safeToRemoveDaily = $false

        if ($entry.daily_minimum_target_records -and
            (Test-Path -LiteralPath $dailyTargetPath -PathType Leaf)) {

            $dailyStatus = Get-DailyTargetStatus $dailyTargetPath

            $safeToRemoveDaily =
                $dailyStatus.Kind -eq "data" -and
                $dailyStatus.Records -ge
                    [long]$entry.daily_minimum_target_records -and
                (
                    -not $entry.daily_target_first_date_ticks -or
                    $dailyStatus.FirstDateTicks -eq
                        [long]$entry.daily_target_first_date_ticks
                )
        }

        $retire += [pscustomobject]@{
            Source = $sourcePath
            SourceName = $sourceName
            Target = $targetPath
            TargetName = [IO.Path]::GetFileName($targetPath)
            RemoveTarget = [bool]$safeToRemove
            DailyTarget = $dailyTargetPath
            RemoveDailyTarget = [bool]$safeToRemoveDaily
            Reason =
                if ($safeToRemove) {
                    "outside rolling Rithmic history window"
                }
                else {
                    "outside window but intraday target no longer matches saved metadata"
                }
        }
    }

    $ready = @()
    $deferredScid = @()
    $decisionCandidates = @()
    $preflightLines =
        New-Object System.Collections.Generic.List[string]
    $unchanged = 0
    $unverified = 0

    $fullValidationChoiceMade = $false
    $allowFullValidation = $true

    foreach ($candidate in $candidates) {
        if (-not $scales.ContainsKey($candidate.Group)) {
            $unverified++
            continue
        }

        $signature = $null
        $targetStatus = $null

        if ($candidate.HasScid) {
            $signature =
                [SierraHistoryBridge.ScidBridge]::GetQuickSignature(
                    $candidate.Source)

            $targetStatus =
                Get-TargetStatus $candidate.Target
        }

        $candidate |
            Add-Member -NotePropertyName Signature -NotePropertyValue $signature

        $candidate |
            Add-Member -NotePropertyName TargetStatus -NotePropertyValue $targetStatus

        $stateEntry =
            if ($stateTable.ContainsKey($candidate.StateKey)) {
                $stateTable[$candidate.StateKey]
            }
            else {
                $null
            }

        $candidate |
            Add-Member `
                -NotePropertyName PreviousState `
                -NotePropertyValue $stateEntry

        $scidCurrent =
            if (-not $candidate.HasScid) {
                $true
            }
            else {
                -not $Force -and
                (Test-ProcessedTargetStillValid `
                    $stateEntry `
                    $signature `
                    $targetStatus)
            }

        $scidStateRefreshed = $false

        if ($candidate.HasScid -and
            -not $Force -and
            $targetStatus -and
            $targetStatus.Exists -and
            $targetStatus.Kind -eq "data") {

            if ($scidCurrent -and
                $stateEntry -and
                $stateEntry -isnot [string] -and
                [string]$stateEntry.source_signature -ne $signature) {

                $stateEntry =
                    Update-ScidStateMetadata `
                        $stateEntry `
                        $candidate `
                        $signature `
                        $targetStatus

                $stateTable[$candidate.StateKey] =
                    $stateEntry

                $stateDirty = $true
                $scidStateRefreshed = $true
            }
            elseif (-not $scidCurrent -and
                $scales.ContainsKey($candidate.Group)) {

                try {
                    $alreadyConverted =
                        [SierraHistoryBridge.ScidBridge]::QuickConvertedPairMatches(
                            $candidate.Source,
                            $candidate.Target,
                            [double]$scales[$candidate.Group])

                    if ($alreadyConverted) {
                        $scidCurrent = $true

                        $stateEntry =
                            Update-ScidStateMetadata `
                                $stateEntry `
                                $candidate `
                                $signature `
                                $targetStatus

                        $stateTable[$candidate.StateKey] =
                            $stateEntry

                        $stateDirty = $true
                        $scidStateRefreshed = $true
                    }
                }
                catch {
                    # A changing pair remains dirty and will go through normal
                    # preflight/defer handling below.
                }
            }
        }

        $dailySignature = $null
        $dailyTargetStatus = $null
        $dailyCurrent = $true
        $dailyStateRefreshed = $false

        if ($candidate.DailyAvailable) {
            $dailySignature =
                Get-DailySourceSignature `
                    $candidate.DailySource

            $dailyTargetStatus =
                Get-DailyTargetStatus `
                    $candidate.DailyTarget

            $dailyCurrent =
                -not $Force -and
                (Test-ProcessedDailyTargetStillValid `
                    $stateEntry `
                    $dailySignature `
                    $dailyTargetStatus)

            # Older builds used modification time in the DLY signature. A
            # completed SCID download, Sierra maintenance, or a file copy can
            # therefore make the source look changed even when its Daily rows
            # are identical. If the saved signature does not match, compare
            # the actual Daily data before deciding to rewrite the target.
            if (-not $dailyCurrent -and
                -not $Force -and
                $dailyTargetStatus.Exists -and
                $dailyTargetStatus.Kind -eq "data" -and
                $scales.ContainsKey($candidate.Group)) {

                try {
                    $dailyCurrent =
                        [SierraHistoryBridge.DailyBridge]::IsSynchronized(
                            $candidate.DailySource,
                            $candidate.DailyTarget,
                            [double]$scales[$candidate.Group])

                    if ($dailyCurrent) {
                        $stateEntry =
                            Update-DailyStateMetadata `
                                $stateEntry `
                                $candidate `
                                $dailySignature `
                                $dailyTargetStatus

                        $stateTable[$candidate.StateKey] =
                            $stateEntry

                        $stateDirty = $true
                        $dailyStateRefreshed = $true
                    }
                }
                catch {
                    $dailyCurrent = $false
                }
            }
        }

        if ($scidStateRefreshed) {
            $candidate |
                Add-Member `
                    -NotePropertyName PreviousState `
                    -NotePropertyValue $stateEntry `
                    -Force
        }

        if ($dailyStateRefreshed) {
            $candidate |
                Add-Member `
                    -NotePropertyName PreviousState `
                    -NotePropertyValue $stateEntry `
                    -Force
        }

        $candidate |
            Add-Member -NotePropertyName DailySignature -NotePropertyValue $dailySignature

        $candidate |
            Add-Member -NotePropertyName DailyTargetStatus -NotePropertyValue $dailyTargetStatus

        $candidate |
            Add-Member `
                -NotePropertyName ScidNeeded `
                -NotePropertyValue (
                    $candidate.HasScid -and
                    -not $scidCurrent)

        $candidate |
            Add-Member `
                -NotePropertyName DailyNeeded `
                -NotePropertyValue (
                    $candidate.DailyAvailable -and
                    -not $dailyCurrent)

        if (-not $candidate.ScidNeeded -and
            -not $candidate.DailyNeeded) {
            $unchanged++
            continue
        }

        $candidate |
            Add-Member `
                -NotePropertyName LiveScidUpdate `
                -NotePropertyValue (
                    Test-LiveScidCandidate $candidate)

        $candidate |
            Add-Member `
                -NotePropertyName ScidSkipped `
                -NotePropertyValue $false

        $candidate |
            Add-Member `
                -NotePropertyName ScidDeferred `
                -NotePropertyValue $false

        $candidate |
            Add-Member `
                -NotePropertyName ScidDeferReason `
                -NotePropertyValue $null

        $candidate |
            Add-Member `
                -NotePropertyName ScidValidation `
                -NotePropertyValue $null

        $candidate |
            Add-Member `
                -NotePropertyName ScidFileValidation `
                -NotePropertyValue $null

        $candidate |
            Add-Member `
                -NotePropertyName ScidPairGrade `
                -NotePropertyValue "NONE"

        $candidate |
            Add-Member `
                -NotePropertyName ScidCoverage `
                -NotePropertyValue $null

        $candidate |
            Add-Member `
                -NotePropertyName ScidNeedsDecision `
                -NotePropertyValue $false

        $initialScidAction =
            if ($candidate.LiveScidUpdate) {
                "live-merge"
            }
            else {
                "replace"
            }

        $candidate |
            Add-Member `
                -NotePropertyName ScidAction `
                -NotePropertyValue $initialScidAction

        $candidate |
            Add-Member `
                -NotePropertyName ScidTemporaryMerge `
                -NotePropertyValue $false

        $candidate |
            Add-Member `
                -NotePropertyName ScidValidationReference `
                -NotePropertyValue (
                    Get-ScidValidationReference `
                        $candidate `
                        $resolvedDataFolder)

        $candidate |
            Add-Member `
                -NotePropertyName CreateRithmicBaseline `
                -NotePropertyValue $false

        if ($candidate.ScidValidationReference) {
            $candidate.CreateRithmicBaseline =
                [bool]$candidate.ScidValidationReference.CreateBaseline
        }

        if ($candidate.ScidNeeded) {
            $deferReason =
                Get-HistoricalScidDeferReason `
                    $candidate

            if ($deferReason) {
                $candidate.ScidDeferred = $true
                $candidate.ScidSkipped = $true
                $candidate.ScidDeferReason =
                    $deferReason
                $candidate.ScidAction = "defer"
                $candidate.ScidNeeded = $false
                $deferredScid += $candidate
            }
        }

        if ($candidate.HasScid -and
            -not $candidate.ScidDeferred) {

            if ($candidate.ScidNeeded -and
                -not $candidate.LiveScidUpdate -and
                -not $fullValidationChoiceMade) {

                $fullValidationChoiceMade = $true

                if ($Interactive -and -not $Yes) {
                    Write-Host
                    Write-Host (
                        "Full SCID validation is needed for changed or unknown historical files.") `
                        -ForegroundColor Yellow
                    Write-Host (
                        "It scans complete multi-GB files and can take several minutes.")
                    Write-Host (
                        "If skipped, those SCID updates are left untouched and deferred.")

                    $answer =
                        Read-Host "Run full SCID validation now? [Y/n]"

                    if ($answer.Trim().ToLowerInvariant() -in @("n", "no")) {
                        $allowFullValidation = $false
                    }
                }
            }

            if ($candidate.ScidNeeded -and
                -not $candidate.LiveScidUpdate -and
                -not $allowFullValidation) {

                $candidate.ScidDeferred = $true
                $candidate.ScidSkipped = $true
                $candidate.ScidDeferReason =
                    "full SCID validation skipped by user"
                $candidate.ScidAction = "defer"
                $candidate.ScidNeeded = $false
                $deferredScid += $candidate
            }

            if ($candidate.ScidNeeded -and
                -not $candidate.LiveScidUpdate -and
                $candidate.TargetStatus.Exists -and
                $candidate.TargetStatus.Kind -eq "data" -and
                $scales.ContainsKey($candidate.Group)) {

                try {
                    $validationPrefix =
                        "VALIDATE {0} <-> {1}" -f
                        (Get-CandidateSourceDisplay $candidate),
                        (Get-CandidateTargetDisplay $candidate)

                    if ($candidate.ScidValidationReference.Compressed) {
                        $archiveMeta =
                            $candidate.ScidValidationReference.ArchiveMeta

                        $candidate.ScidValidation =
                            [SierraHistoryBridge.ScidBridge]::ValidatePairGzipTarget(
                                $candidate.Source,
                                $candidate.ScidValidationReference.Path,
                                [long]$archiveMeta.OriginalBytes,
                                [long]$archiveMeta.FirstDateTime,
                                [long]$archiveMeta.LastDateTime,
                                [double]$scales[$candidate.Group],
                                $validationPrefix)
                    }
                    else {
                        $candidate.ScidValidation =
                            [SierraHistoryBridge.ScidBridge]::ValidatePair(
                                $candidate.Source,
                                $candidate.ScidValidationReference.Path,
                                [double]$scales[$candidate.Group],
                                $validationPrefix)
                    }

                    [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                        "$validationPrefix | OK")

                    $candidate.ScidPairGrade =
                        Get-ScidPairGrade `
                            $candidate.ScidValidation

                    $candidate.Records =
                        [long]$candidate.ScidValidation.SourceRecords
                    $candidate.First =
                        [long]$candidate.ScidValidation.SourceFirstDateTime
                    $candidate.Last =
                        [long]$candidate.ScidValidation.SourceLastDateTime
                    $candidate.Size =
                        [long]$candidate.ScidValidation.SourceLength
                    $candidate.ModifiedTicks =
                        [long]$candidate.ScidValidation.SourceWriteTimeUtcTicks
                    $candidate.Signature =
                        [SierraHistoryBridge.ScidBridge]::GetQuickSignature(
                            $candidate.Source)
                }
                catch {
                    [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                        "VALIDATE $(Get-CandidateSourceDisplay $candidate) | DEFERRED | $($_.Exception.Message)")

                    $candidate.ScidDeferred = $true
                    $candidate.ScidSkipped = $true
                    $candidate.ScidDeferReason =
                        $_.Exception.Message
                    $candidate.ScidAction = "defer"
                    $candidate.ScidNeeded = $false
                    $deferredScid += $candidate
                }
            }

            if ($candidate.ScidNeeded -and
                -not $candidate.LiveScidUpdate -and
                -not $candidate.ScidValidation) {

                try {
                    $fileValidationPrefix =
                        "VALIDATE {0}" -f
                        (Get-CandidateSourceDisplay $candidate)

                    $candidate.ScidFileValidation =
                        [SierraHistoryBridge.ScidBridge]::ValidateFile(
                            $candidate.Source,
                            $fileValidationPrefix)

                    [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                        "$fileValidationPrefix | OK")

                    $candidate.Records =
                        [long]$candidate.ScidFileValidation.Records
                    $candidate.First =
                        [long]$candidate.ScidFileValidation.FirstDateTime
                    $candidate.Last =
                        [long]$candidate.ScidFileValidation.LastDateTime
                    $candidate.Size =
                        [long]$candidate.ScidFileValidation.Length
                    $candidate.ModifiedTicks =
                        [long]$candidate.ScidFileValidation.WriteTimeUtcTicks
                    $candidate.Signature =
                        [SierraHistoryBridge.ScidBridge]::GetQuickSignature(
                            $candidate.Source)
                }
                catch {
                    [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                        "VALIDATE $(Get-CandidateSourceDisplay $candidate) | DEFERRED | $($_.Exception.Message)")

                    $candidate.ScidDeferred = $true
                    $candidate.ScidSkipped = $true
                    $candidate.ScidDeferReason =
                        $_.Exception.Message
                    $candidate.ScidAction = "defer"
                    $candidate.ScidNeeded = $false
                    $deferredScid += $candidate
                }
            }

            $candidate.ScidCoverage =
                Get-ScidCoverageAssessment `
                    $candidate `
                    $candidate.ScidValidation

            if ($candidate.ScidNeeded -and
                -not $candidate.LiveScidUpdate) {

                $sourceOutOfOrder =
                    if ($candidate.ScidValidation) {
                        [long]$candidate.ScidValidation.SourceOutOfOrderRecords
                    }
                    elseif ($candidate.ScidFileValidation) {
                        [long]$candidate.ScidFileValidation.OutOfOrderRecords
                    }
                    else {
                        0
                    }

                $targetOutOfOrder =
                    if ($candidate.ScidValidation) {
                        [long]$candidate.ScidValidation.TargetOutOfOrderRecords
                    }
                    else {
                        0
                    }

                $ambiguousCoverage =
                    $candidate.ScidCoverage.TargetStartsEarlier -or
                    (
                        $candidate.ScidCoverage.TargetExtendsLater -and
                        -not $candidate.ScidCoverage.SourceIncomplete -and
                        -not $candidate.DailyAvailable
                    )

                $comparisonIssue =
                    $candidate.ScidValidation -and
                    $candidate.ScidPairGrade -ne "STRONG"

                if ($sourceOutOfOrder -gt 0 -and
                    (-not $candidate.TargetStatus.Exists -or
                     $candidate.TargetStatus.Kind -ne "data")) {

                    $candidate.ScidDeferred = $true
                    $candidate.ScidSkipped = $true
                    $candidate.ScidDeferReason =
                        "source contains $sourceOutOfOrder out-of-order timestamp record(s)"
                    $candidate.ScidAction = "defer"
                    $candidate.ScidNeeded = $false
                    $deferredScid += $candidate
                }
                elseif ($candidate.ScidCoverage.SourceIncomplete) {
                    if ($candidate.TargetStatus.Exists -and
                        $candidate.TargetStatus.Kind -eq "data") {

                        $candidate.ScidNeedsDecision = $true
                        $candidate.ScidAction = "decision"
                        $decisionCandidates += $candidate
                    }
                    else {
                        $candidate.ScidDeferred = $true
                        $candidate.ScidSkipped = $true
                        $candidate.ScidDeferReason =
                            $candidate.ScidCoverage.Summary
                        $candidate.ScidAction = "defer"
                        $candidate.ScidNeeded = $false
                        $deferredScid += $candidate
                    }
                }
                elseif ($sourceOutOfOrder -gt 0 -or
                    $ambiguousCoverage -or
                    $comparisonIssue) {

                    $candidate.ScidNeedsDecision = $true
                    $candidate.ScidAction = "decision"
                    $decisionCandidates += $candidate
                }
                elseif ($targetOutOfOrder -gt 0) {
                    # The source is complete and the pair comparison is strong;
                    # replacing the anomalous target is an unambiguous repair.
                    $candidate.ScidAction = "replace"
                }
            }
        }

        if ($candidate.HasScid) {
            $preflightLine =
                "{0} -> {1} | {2}" -f
                (Get-CandidateSourceDisplay $candidate),
                (Get-CandidateTargetDisplay $candidate),
                (Get-ScidValidationSummary $candidate)

            if ($candidate.ScidCoverage -and
                $candidate.ScidCoverage.Summary) {
                $preflightLine +=
                    " | $($candidate.ScidCoverage.Summary)"
            }

            if ($candidate.ScidValidation) {
                $richness =
                    " | rich source={0:0.00}% target={1:0.00}%" -f
                    $candidate.ScidValidation.SourceRichPercent,
                    $candidate.ScidValidation.TargetRichPercent

                $preflightLine += $richness
            }
            elseif ($candidate.ScidFileValidation) {
                $preflightLine +=
                    " | source rich={0:0.00}%" -f
                    $candidate.ScidFileValidation.RichPercent

                if ($candidate.ScidFileValidation.OutOfOrderRecords -gt 0) {
                    $preflightLine +=
                        " | source out-of-order={0:N0}" -f
                        $candidate.ScidFileValidation.OutOfOrderRecords
                }
            }

            $preflightLines.Add($preflightLine)
        }

        if ($candidate.ScidNeeded -or
            $candidate.DailyNeeded) {
            $ready += $candidate
        }
    }

    $preflightLogPath = $null

    if ($preflightLines.Count -gt 0) {
        $bridgePaths =
            Get-BridgePaths $resolvedDataFolder

        $preflightLogDirectory =
            $bridgePaths.Logs

        New-Item `
            -ItemType Directory `
            -Force `
            -Path $preflightLogDirectory |
            Out-Null

        $preflightTimestamp =
            Get-Date -Format "yyyyMMdd-HHmmss"

        $preflightLogPath =
            Join-Path `
                $preflightLogDirectory `
                "preflight-$preflightTimestamp.log"

        $preflightOutput =
            New-Object System.Collections.Generic.List[string]

        $preflightOutput.Add(
            "Sierra History Bridge v$Version - SCID preflight")
        $preflightOutput.Add(
            "Data folder: $resolvedDataFolder")
        $preflightOutput.Add(
            "Created: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        $preflightOutput.Add(
            "Strong-match thresholds: coverage >=99%, volume/sec >=98%, last-price >=99%, aggregate-volume-diff <=0.5%")
        $preflightOutput.Add("")

        foreach ($line in $preflightLines) {
            $preflightOutput.Add($line)
        }

        $preflightOutput |
            Set-Content `
                -LiteralPath $preflightLogPath `
                -Encoding UTF8

        Write-Host
        Write-Host "SCID preflight validation:"

        foreach ($line in $preflightLines) {
            Write-Host "  $line"
        }

        Write-Host "  Report: $preflightLogPath"
    }

    if ($decisionCandidates.Count -gt 0) {
        Write-Host
        Write-Host (
            "{0} SCID update(s) require a decision before any history files are changed." -f
            $decisionCandidates.Count) `
            -ForegroundColor Yellow

        foreach ($candidate in $decisionCandidates) {
            Write-Host
            Write-Host (
                "Decision: {0} -> {1}" -f
                (Get-CandidateSourceDisplay $candidate),
                (Get-CandidateTargetDisplay $candidate)) `
                -ForegroundColor Yellow

            Write-Host (
                "  Validation: {0}" -f
                (Get-ScidValidationSummary $candidate))

            if ($candidate.ScidCoverage -and
                $candidate.ScidCoverage.Summary) {
                Write-Host (
                    "  Coverage:   {0}" -f
                    $candidate.ScidCoverage.Summary)
            }

            if ($candidate.ScidValidation) {
                Write-Host (
                    "  Records:    source {0:N0} | Rithmic {1:N0}" -f
                    $candidate.ScidValidation.SourceRecords,
                    $candidate.ScidValidation.TargetRecords)

                if ($candidate.ScidValidation.SourceOutOfOrderRecords -gt 0 -or
                    $candidate.ScidValidation.TargetOutOfOrderRecords -gt 0) {

                    Write-Host (
                        "  Ordering:   source {0:N0} out-of-order | Rithmic {1:N0}" -f
                        $candidate.ScidValidation.SourceOutOfOrderRecords,
                        $candidate.ScidValidation.TargetOutOfOrderRecords) `
                        -ForegroundColor Yellow
                }
            }

            $canTemporaryMerge =
                $candidate.ScidCoverage -and
                $candidate.ScidCoverage.SourceIncomplete -and
                $candidate.ScidCoverage.TargetExtendsLater -and
                -not $candidate.ScidCoverage.TargetStartsEarlier -and
                $candidate.ScidValidation -and
                $candidate.ScidValidationReference.Independent -and
                $candidate.ScidPairGrade -eq "STRONG" -and
                $candidate.ScidValidation.SourceOutOfOrderRecords -eq 0 -and
                $candidate.ScidValidation.TargetOutOfOrderRecords -eq 0

            $sourceStructuralIssue =
                ($candidate.ScidValidation -and
                 $candidate.ScidValidation.SourceOutOfOrderRecords -gt 0) -or
                ($candidate.ScidFileValidation -and
                 $candidate.ScidFileValidation.OutOfOrderRecords -gt 0)

            if ($Yes) {
                $selection = "1"
            }
            else {
                Write-Host "  1. Keep the Rithmic target and defer this SCID update. [recommended]"

                if ($sourceStructuralIssue) {
                    Write-Host "  2. Cancel the entire run."
                    $validSelections = @("1", "2")
                }
                elseif ($canTemporaryMerge) {
                    Write-Host (
                        "  2. Temporary merge: verified SC Data overlap + Rithmic coverage beyond the source.")
                    Write-Host (
                        "     The SCID remains pending and will be rebuilt when SC Data is complete.")
                    Write-Host "  3. Cancel the entire run."
                    $validSelections = @("1", "2", "3")
                }
                elseif (-not $candidate.ScidCoverage.SourceIncomplete) {
                    Write-Host "  2. Replace the Rithmic target with the SC Data source despite the warning."
                    Write-Host "  3. Cancel the entire run."
                    $validSelections = @("1", "2", "3")
                }
                else {
                    Write-Host "  2. Cancel the entire run."
                    $validSelections = @("1", "2")
                }

                do {
                    $selection =
                        (Read-Host "Selection").Trim()
                }
                until ($validSelections -contains $selection)
            }

            if ($selection -eq "1") {
                $candidate.ScidDeferred = $true
                $candidate.ScidSkipped = $true
                $candidate.ScidNeedsDecision = $false
                $candidate.ScidAction = "defer"
                $candidate.ScidNeeded = $false

                if (-not $candidate.ScidDeferReason) {
                    $candidate.ScidDeferReason =
                        if ($candidate.ScidCoverage.Summary) {
                            $candidate.ScidCoverage.Summary
                        }
                        else {
                            "preflight validation requires review"
                        }
                }

                if ($deferredScid -notcontains $candidate) {
                    $deferredScid += $candidate
                }
            }
            elseif ($selection -eq "2" -and $canTemporaryMerge) {
                $candidate.ScidTemporaryMerge = $true
                $candidate.ScidNeedsDecision = $false
                $candidate.ScidAction = "temporary-merge"
                $candidate.ScidNeeded = $true
            }
            elseif ($selection -eq "2" -and
                -not $sourceStructuralIssue -and
                -not $candidate.ScidCoverage.SourceIncomplete) {

                $candidate.ScidNeedsDecision = $false
                $candidate.ScidAction = "replace-override"
                $candidate.ScidNeeded = $true
            }
            else {
                Write-Host "Cancelled. No files were changed."
                return 0
            }
        }

        $ready =
            @(
                $ready |
                Where-Object {
                    $_.ScidNeeded -or
                    $_.DailyNeeded
                }
            )
    }

    Write-Host
    Write-Host (
        "Plan: {0} ready | {1} deferred SCID | {2} unchanged | {3} outside window | {4} retire | {5} unverified" -f
        $ready.Count,
        $deferredScid.Count,
        $unchanged,
        $archiveOnly.Count,
        $retire.Count,
        $unverified)

    foreach ($candidate in $ready) {
        $scidPlan =
            if ($candidate.ScidDeferred) {
                "SCID deferred - $($candidate.ScidDeferReason)"
            }
            elseif (-not $candidate.HasScid) {
                "SCID not present"
            }
            elseif ($candidate.ScidNeeded) {
                if ($candidate.ScidTemporaryMerge) {
                    "SCID temporary merge [pending]"
                }
                elseif ($candidate.ScidAction -eq "replace-override") {
                    "SCID replace [user override]"
                }
                elseif (-not $candidate.TargetStatus.Exists) {
                    "SCID create"
                }
                elseif ($candidate.TargetStatus.Kind -eq "placeholder") {
                    "SCID replace placeholder"
                }
                elseif ($candidate.LiveScidUpdate) {
                    "SCID live merge"
                }
                else {
                    if ($candidate.ScidValidationReference -and
                        $candidate.ScidValidationReference.Independent) {

                        "SCID cross-feed validated replace"
                    }
                    else {
                        "SCID replace [managed consistency check]"
                    }
                }
            }
            else {
                "SCID current"
            }

        $dailyPlan =
            if (-not $candidate.DailyAvailable) {
                if ($candidate.DailyError) {
                    "DLY invalid source"
                }
                else {
                    "DLY not present"
                }
            }
            elseif ($candidate.DailyNeeded) {
                if (-not $candidate.DailyTargetStatus.Exists) {
                    "DLY create"
                }
                else {
                    "DLY update"
                }
            }
            else {
                "DLY current"
            }

        if ($candidate.LiveScidUpdate) {
            $scidPlan += " [LIVE]"
        }

        Write-Host (
            "  UPDATE  {0} -> {1} | {2} | {3}" -f
            (Get-CandidateSourceDisplay $candidate),
            (Get-CandidateTargetDisplay $candidate),
            $scidPlan,
            $dailyPlan)
    }

    $readyStateKeys =
        @(
            $ready |
            ForEach-Object { $_.StateKey }
        )

    foreach ($candidate in $deferredScid) {
        if ($readyStateKeys -notcontains
            $candidate.StateKey) {

            Write-Host (
                "  DEFER   {0} -> {1} | SCID | {2}" -f
                (Get-CandidateSourceDisplay $candidate),
                (Get-CandidateTargetDisplay $candidate),
                $candidate.ScidDeferReason) `
                -ForegroundColor Yellow
        }
    }

    foreach ($item in $retire) {
        $action =
            if ($item.RemoveTarget) { "RETIRE" } else { "STATE" }

        $dailyNote =
            if ($item.RemoveDailyTarget) { " + DLY" } else { "" }

        Write-Host (
            "  {0,-7} {1} -> {2}{3} | {4}" -f
            $action,
            (Get-CompactName $item.SourceName),
            (Get-CompactName $item.TargetName),
            $dailyNote,
            $item.Reason)
    }

    if ($ready.Count -eq 0 -and $retire.Count -eq 0) {
        if ($stateDirty) {
            Save-JsonFile `
                $StatePath `
                (Convert-HashtableToObject $stateTable)
        }

        Write-Host

        if ($deferredScid.Count -gt 0) {
            Write-Host (
                "{0} SCID update(s) deferred because the source is not ready." -f
                $deferredScid.Count) `
                -ForegroundColor Yellow

            Write-Host (
                "Wait for the SC Data download to finish, then run the bridge again.")
        }
        else {
            Write-Host "Nothing needs updating."
        }

        return 0
    }

    $storageFree =
        Get-AvailableFreeBytes `
            $resolvedDataFolder

    $largestScratch = 0L
    $newTargetBytes = 0L

    foreach ($storageCandidate in $ready) {
        if (-not $storageCandidate.ScidNeeded) {
            continue
        }

        $scratch =
            [long]$storageCandidate.Size

        if (($storageCandidate.LiveScidUpdate -or
             $storageCandidate.ScidTemporaryMerge) -and
            $storageCandidate.TargetStatus -and
            $storageCandidate.TargetStatus.Exists) {

            $scratch +=
                [long]$storageCandidate.TargetStatus.Length
        }

        if ($scratch -gt $largestScratch) {
            $largestScratch = $scratch
        }

        if (-not $storageCandidate.TargetStatus -or
            -not $storageCandidate.TargetStatus.Exists) {

            $newTargetBytes +=
                [long]$storageCandidate.Size
        }
    }

    if ($storageFree -ge 0) {
        $projectedAfterCreates =
            $storageFree -
            $newTargetBytes

        Write-Host
        Write-Host (
            "Storage: {0} free | largest temporary SCID up to {1} | new targets add about {2}" -f
            (Format-StorageBytes $storageFree),
            (Format-StorageBytes $largestScratch),
            (Format-StorageBytes $newTargetBytes))

        if ($storageFree -lt
                ($largestScratch + 256MB) -or
            $projectedAfterCreates -lt 512MB) {

            Write-Host (
                "Storage warning: available space is tight. Each SCID is checked again before writing; unsafe updates will be deferred." ) `
                -ForegroundColor Yellow
        }
    }

    if ($DryRun) {
        Write-Host
        Write-Host "Dry run complete. No files were changed."
        return 0
    }

    if (-not $Yes) {
        Write-Host
        $response = Read-Host "Apply this history update plan? [Y/n]"
        if (-not [string]::IsNullOrWhiteSpace($response)) {
            $normalized = $response.Trim().ToLowerInvariant()
            if ($normalized -ne "y" -and $normalized -ne "yes") {
                Write-Host "Cancelled. No files were changed."
                return 0
            }
        }
    }

    $sierraWasRunning =
        Test-SierraChartRunning

    $sierraHandling = "not-running"
    $reloadAfterUpdate = $false
    $skippedLiveNames =
        New-Object System.Collections.Generic.List[string]

    $liveScidCandidates =
        @(
            $ready |
            Where-Object {
                $_.ScidNeeded -and
                $_.LiveScidUpdate
            }
        )

    $remainingWorkIfLiveSkipped =
        @(
            $ready |
            Where-Object {
                $_.DailyNeeded -or
                (
                    $_.ScidNeeded -and
                    -not $_.LiveScidUpdate
                )
            }
        ).Count + $retire.Count

    if ($sierraWasRunning -and
        $liveScidCandidates.Count -gt 0) {

        Write-Host
        Write-Host "Live intraday update(s) detected:" -ForegroundColor Yellow

        foreach ($candidate in $liveScidCandidates) {
            Write-Host (
                "  {0}" -f
                (Get-CandidateTargetDisplay $candidate))
        }

        Write-Host
        Write-Host (
            "These SCID files contain recent data and can still receive writes " +
            "while Sierra Chart is connected.")

        if ($Yes) {
            if ($remainingWorkIfLiveSkipped -gt 0) {
                $choice = "3"
            }
            else {
                $choice = "4"
            }
        }
        else {
            Write-Host
            Write-Host "Choose how to continue:"
            Write-Host "  1. Update all - disconnect Sierra Chart and close affected chartbooks."
            Write-Host "  2. Update all - close Sierra Chart."
            if ($remainingWorkIfLiveSkipped -gt 0) {
                Write-Host "  3. Skip live SCID updates and continue with the remaining updates."
            }
            Write-Host "  4. Cancel."

            do {
                $choice =
                    (Read-Host "Selection").Trim()

                $validChoices =
                    if ($remainingWorkIfLiveSkipped -gt 0) {
                        @("1", "2", "3", "4")
                    }
                    else {
                        @("1", "2", "4")
                    }
            }
            until ($validChoices -contains $choice)
        }

        switch ($choice) {
            "1" {
                $sierraHandling = "disconnected"

                Write-Host
                Write-Host "In Sierra Chart:"
                Write-Host "  1. File > Disconnect"
                Write-Host "  2. Close chartbooks using the live file(s)."
                Write-Host "     File > Close All Chartbooks is the simplest option."
                Write-Host

                Read-Host "Press Enter when Sierra Chart is disconnected and the affected charts are closed" |
                    Out-Null
            }

            "2" {
                $sierraHandling = "closed"

                Write-Host
                Write-Host "Close Sierra Chart to continue."

                while (Test-SierraChartRunning) {
                    Read-Host "Press Enter after Sierra Chart is closed" |
                        Out-Null
                }

                Write-Host "Sierra Chart: CLOSED"
            }

            "3" {
                $sierraHandling = "skip-live"
                $reloadAfterUpdate = $true

                foreach ($candidate in $liveScidCandidates) {
                    $candidate.ScidSkipped = $true
                    $candidate.ScidNeeded = $false

                    $skippedLiveNames.Add(
                        (Get-CandidateTargetDisplay $candidate))
                }

                $ready =
                    @(
                        $ready |
                        Where-Object {
                            $_.ScidNeeded -or
                            $_.DailyNeeded
                        }
                    )

                Write-Host
                Write-Host (
                    "Live SCID update(s) skipped. Continuing with {0} remaining contract update(s)." -f
                    $ready.Count)
            }

            "4" {
                Write-Host "Cancelled. No files were changed."
                return 0
            }
        }
    }
    elseif ($sierraWasRunning) {
        $sierraHandling = "open-historical"
        $reloadAfterUpdate = $true

        Write-Host
        Write-Host (
            "Sierra Chart is running. No live SCID files are being updated; " +
            "Sierra Chart can remain open.")
    }

    $liveValidationCandidates =
        @(
            $ready |
            Where-Object {
                $_.ScidNeeded -and
                $_.LiveScidUpdate -and
                $_.TargetStatus.Exists -and
                $_.TargetStatus.Kind -eq "data"
            }
        )

    if ($liveValidationCandidates.Count -gt 0) {
        Write-Host
        Write-Host "Live SCID overlap validation:"

        foreach ($candidate in $liveValidationCandidates) {
            try {
                $candidate.ScidValidationReference =
                    [pscustomobject]@{
                        Path = $candidate.Target
                        Kind = "live Rithmic target"
                        Independent = $true
                        CreateBaseline = $candidate.CreateRithmicBaseline
                    }

                $validationPrefix =
                    "VALIDATE LIVE {0} <-> {1}" -f
                    (Get-CandidateSourceDisplay $candidate),
                    (Get-CandidateTargetDisplay $candidate)

                $candidate.ScidValidation =
                    [SierraHistoryBridge.ScidBridge]::ValidatePair(
                        $candidate.Source,
                        $candidate.Target,
                        [double]$scales[$candidate.Group],
                        $validationPrefix)

                $candidate.ScidPairGrade =
                    Get-ScidPairGrade `
                        $candidate.ScidValidation

                $candidate.Records =
                    [long]$candidate.ScidValidation.SourceRecords
                $candidate.First =
                    [long]$candidate.ScidValidation.SourceFirstDateTime
                $candidate.Last =
                    [long]$candidate.ScidValidation.SourceLastDateTime
                $candidate.Size =
                    [long]$candidate.ScidValidation.SourceLength
                $candidate.ModifiedTicks =
                    [long]$candidate.ScidValidation.SourceWriteTimeUtcTicks
                $candidate.Signature =
                    "$($candidate.Size)|$($candidate.ModifiedTicks)|$($candidate.Last)"

                [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                    "$validationPrefix | $($candidate.ScidPairGrade)")

                $liveValidationIssue =
                    $candidate.ScidPairGrade -ne "STRONG" -or
                    $candidate.ScidValidation.SourceOutOfOrderRecords -gt 0 -or
                    $candidate.ScidValidation.TargetOutOfOrderRecords -gt 0

                if ($liveValidationIssue) {
                    Write-Host
                    Write-Host (
                        "Live data comparison warning: {0}" -f
                        (Get-ScidValidationSummary $candidate)) `
                        -ForegroundColor Yellow

                    if ($Yes) {
                        $liveChoice = "1"
                    }
                    else {
                        Write-Host "  1. Skip this live SCID update. [recommended]"
                        Write-Host "  2. Continue with the live merge despite the warning."
                        Write-Host "  3. Cancel the entire run."

                        do {
                            $liveChoice =
                                (Read-Host "Selection").Trim()
                        }
                        until (@("1", "2", "3") -contains $liveChoice)
                    }

                    if ($liveChoice -eq "1") {
                        $candidate.ScidSkipped = $true
                        $candidate.ScidDeferred = $true
                        $candidate.ScidDeferReason =
                            "live preflight validation requires review"
                        $candidate.ScidAction = "defer"
                        $candidate.ScidNeeded = $false

                        if ($deferredScid -notcontains $candidate) {
                            $deferredScid += $candidate
                        }
                    }
                    elseif ($liveChoice -eq "3") {
                        Write-Host "Cancelled. No files were changed."
                        return 0
                    }
                }
            }
            catch {
                $candidate.ScidSkipped = $true
                $candidate.ScidDeferred = $true
                $candidate.ScidDeferReason =
                    $_.Exception.Message
                $candidate.ScidAction = "defer"
                $candidate.ScidNeeded = $false

                if ($deferredScid -notcontains $candidate) {
                    $deferredScid += $candidate
                }

                Write-Host (
                    "  DEFER {0}: {1}" -f
                    (Get-CandidateTargetDisplay $candidate),
                    $_.Exception.Message) `
                    -ForegroundColor Yellow
            }
        }

        $ready =
            @(
                $ready |
                Where-Object {
                    $_.ScidNeeded -or
                    $_.DailyNeeded
                }
            )
    }

    Write-Host
    Write-Host "[4/4] Update"

    $retiredTargets = 0
    $retiredState = 0
    $retireWarnings = 0

    foreach ($item in $retire) {
        if ($item.RemoveTarget) {
            try {
                if (Test-Path -LiteralPath $item.Target -PathType Leaf) {
                    [void](Remove-BridgeOwnedFileAndPrune `
                        $item.Target `
                        $resolvedDataFolder)

                    $retiredTargets++
                }

                if ($item.RemoveDailyTarget -and
                    (Test-Path -LiteralPath $item.DailyTarget -PathType Leaf)) {

                    [void](Remove-BridgeOwnedFileAndPrune `
                        $item.DailyTarget `
                        $resolvedDataFolder)

                    $retiredTargets++
                }

                if ($stateTable.ContainsKey($item.Source)) {
                    $stateTable.Remove($item.Source)
                    $retiredState++
                }

                $retiredTypes =
                    if ($item.RemoveDailyTarget) {
                        "SCID + DLY"
                    }
                    else {
                        "SCID"
                    }

                Write-Host (
                    "  RETIRED {0} | {1} | source {2}" -f
                    (Get-CompactName $item.TargetName),
                    $retiredTypes,
                    (Get-CompactName $item.SourceName))
            }
            catch {
                $retireWarnings++
                Write-Host (
                    "  RETIRE WARNING {0} | {1}" -f
                    (Get-CompactName $item.TargetName),
                    $_.Exception.Message) -ForegroundColor Yellow
            }
        }
        elseif ($item.Reason -eq "managed intraday target already missing" -or
                $item.Reason -eq "target alias reused by newer eligible contract") {
            if ($stateTable.ContainsKey($item.Source)) {
                $stateTable.Remove($item.Source)
                $retiredState++
            }
        }
        else {
            $retireWarnings++
            Write-Host (
                "  RETIRE SKIPPED {0} | {1}" -f
                (Get-CompactName $item.TargetName),
                $item.Reason) -ForegroundColor Yellow
        }
    }

    $bridgePaths =
        Get-BridgePaths $resolvedDataFolder

    $backupDirectory = $bridgePaths.Recovery
    $logDirectory = $bridgePaths.Logs

    New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $logPath = Join-Path $logDirectory "bridge-$timestamp.log"
    $log = New-Object System.Collections.Generic.List[string]

    $log.Add("Sierra History Bridge v$Version")
    $log.Add("Data folder: $resolvedDataFolder")
    $log.Add("Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $log.Add("")

    if ($preflightLogPath) {
        $log.Add("Preflight report: $preflightLogPath")
        $log.Add("")
    }

    if ($preflightLines.Count -gt 0) {
        $log.Add("SCID preflight validation:")
        foreach ($line in $preflightLines) {
            $log.Add("  $line")
        }
        $log.Add("")
    }

    # Create the log before file updates begin.
    $log | Set-Content -LiteralPath $logPath -Encoding UTF8

    $updated = 0
    $failed = 0
    $runtimeDeferred = 0
    $warningFiles = 0
    $updateStopwatch = [Diagnostics.Stopwatch]::StartNew()

    for ($index = 0; $index -lt $ready.Count; $index++) {
        $candidate = $ready[$index]

        $sourceDisplay =
            Get-CandidateSourceDisplay $candidate
        $targetDisplay =
            Get-CandidateTargetDisplay $candidate
        $statusPrefix =
            "[{0}/{1}] {2} -> {3}" -f
            ($index + 1),
            $ready.Count,
            $sourceDisplay,
            $targetDisplay

        $scidResult = $null
        $dailyResult = $null
        $operationCommitted = $false

        try {
            if ($candidate.ScidNeeded) {
                if (($candidate.ScidValidation -or
                     $candidate.ScidFileValidation) -and
                    -not (Test-ScidPreflightSnapshotCurrent $candidate)) {

                    throw (
                        "PREFLIGHT_SNAPSHOT_CHANGED: source or target changed after validation. " +
                        "No SCID replacement was performed; rerun preflight.")
                }

                $scidResult =
                    [SierraHistoryBridge.ScidBridge]::Convert(
                        $candidate.Source,
                        $candidate.Target,
                        [double]$scales[$candidate.Group],
                        $backupDirectory,
                        [bool](
                            $candidate.LiveScidUpdate -or
                            $candidate.ScidTemporaryMerge),
                        [bool]$candidate.CreateRithmicBaseline,
                        $statusPrefix)

                [SierraHistoryBridge.ScidBridge]::UpdateStatusLine(
                    "$statusPrefix | VERIFY SCID")

                $targetMeta =
                    [SierraHistoryBridge.ScidBridge]::GetMeta(
                        $candidate.Target)

                if ($targetMeta.Records -ne $scidResult.OutputRecords) {
                    throw (
                        "SCID verification failed. Expected {0:N0} records; target contains {1:N0}." -f
                        $scidResult.OutputRecords,
                        $targetMeta.Records)
                }

                $storageResult =
                    Finalize-ScidBackupStorage `
                        $candidate `
                        $resolvedDataFolder `
                        $backupDirectory

                if ($storageResult.Warning) {
                    $warningFiles++

                    $storageEntry =
                        "STORAGE WARNING $($candidate.TargetName): " +
                        $storageResult.Warning

                    $log.Add($storageEntry)
                    Add-Content `
                        -LiteralPath $logPath `
                        -Value $storageEntry `
                        -Encoding UTF8
                }
                elseif ($storageResult.Archived -or
                    $storageResult.Pruned) {

                    $storageEntry =
                        "STORAGE $($candidate.TargetName) reclaimed_bytes=" +
                        $storageResult.SavedBytes

                    $log.Add($storageEntry)
                    Add-Content `
                        -LiteralPath $logPath `
                        -Value $storageEntry `
                        -Encoding UTF8
                }
            }
            elseif ($candidate.HasScid) {
                $targetMeta =
                    [SierraHistoryBridge.ScidBridge]::GetMeta(
                        $candidate.Target)
            }
            else {
                $targetMeta = $null
            }

            if ($candidate.DailyNeeded) {
                [SierraHistoryBridge.ScidBridge]::UpdateStatusLine(
                    "$statusPrefix | UPDATE DLY")

                $dailyResult =
                    [SierraHistoryBridge.DailyBridge]::Sync(
                        $candidate.DailySource,
                        $candidate.DailyTarget,
                        [double]$scales[$candidate.Group],
                        $backupDirectory)

                $dailyTargetMeta =
                    [SierraHistoryBridge.DailyBridge]::GetMeta(
                        $candidate.DailyTarget)

                if ($dailyTargetMeta.Records -ne
                    $dailyResult.OutputRecords) {
                    throw (
                        "DLY verification failed. Expected {0:N0} records; target contains {1:N0}." -f
                        $dailyResult.OutputRecords,
                        $dailyTargetMeta.Records)
                }

                try {
                    $dailySaved =
                        Finalize-DailyBackupStorage `
                            $candidate `
                            $resolvedDataFolder `
                            $backupDirectory

                    if ($dailySaved -gt 0) {
                        $storageEntry =
                            "STORAGE $($candidate.DailyTargetName) reclaimed_bytes=" +
                            $dailySaved

                        $log.Add($storageEntry)
                        Add-Content `
                            -LiteralPath $logPath `
                            -Value $storageEntry `
                            -Encoding UTF8
                    }
                }
                catch {
                    $warningFiles++

                    $storageEntry =
                        "STORAGE WARNING $($candidate.DailyTargetName): " +
                        $_.Exception.Message

                    $log.Add($storageEntry)
                    Add-Content `
                        -LiteralPath $logPath `
                        -Value $storageEntry `
                        -Encoding UTF8
                }
            }
            elseif ($candidate.DailyAvailable) {
                $dailyTargetMeta =
                    [SierraHistoryBridge.DailyBridge]::GetMeta(
                        $candidate.DailyTarget)
            }
            else {
                $dailyTargetMeta = $null
            }

            $previousState =
                $candidate.PreviousState

            $stateTable[$candidate.StateKey] = [pscustomobject]@{
                source_signature =
                    if ($candidate.ScidSkipped -or
                        $candidate.ScidTemporaryMerge) {
                        if ($previousState) {
                            $previousState.source_signature
                        }
                        else {
                            $null
                        }
                    }
                    elseif ($candidate.HasScid) {
                        $candidate.Signature
                    }
                    else {
                        $null
                    }
                target_path = $candidate.Target
                minimum_target_records =
                    if ($candidate.ScidSkipped -or
                        $candidate.ScidTemporaryMerge) {
                        if ($previousState -and
                            $previousState.minimum_target_records) {
                            [long]$previousState.minimum_target_records
                        }
                        else {
                            0
                        }
                    }
                    elseif ($targetMeta) {
                        [long]$targetMeta.Records
                    }
                    else {
                        0
                    }
                target_first_datetime =
                    if ($candidate.ScidSkipped -or
                        $candidate.ScidTemporaryMerge) {
                        if ($previousState -and
                            $previousState.target_first_datetime) {
                            [long]$previousState.target_first_datetime
                        }
                        else {
                            0
                        }
                    }
                    elseif ($targetMeta) {
                        [long]$targetMeta.FirstDateTime
                    }
                    else {
                        0
                    }
                minimum_target_last_datetime =
                    if ($candidate.ScidSkipped -or
                        $candidate.ScidTemporaryMerge) {
                        if ($previousState -and
                            $previousState.minimum_target_last_datetime) {
                            [long]$previousState.minimum_target_last_datetime
                        }
                        else {
                            0
                        }
                    }
                    elseif ($targetMeta) {
                        [long]$targetMeta.LastDateTime
                    }
                    else {
                        0
                    }
                scid_managed_by_bridge =
                    if ($candidate.ScidSkipped) {
                        if ($previousState -and
                            $previousState.PSObject.Properties["scid_managed_by_bridge"]) {
                            [bool]$previousState.scid_managed_by_bridge
                        }
                        elseif ($previousState -and
                            $previousState.source_signature) {
                            $true
                        }
                        else {
                            $false
                        }
                    }
                    elseif ($candidate.ScidTemporaryMerge) {
                        $true
                    }
                    elseif ($candidate.ScidNeeded -or $scidResult) {
                        $true
                    }
                    elseif ($previousState -and
                        $previousState.PSObject.Properties["scid_managed_by_bridge"]) {
                        [bool]$previousState.scid_managed_by_bridge
                    }
                    else {
                        $false
                    }
                daily_source_signature =
                    if ($candidate.DailyAvailable) {
                        $candidate.DailySignature
                    }
                    else {
                        $null
                    }
                daily_target_path =
                    if ($candidate.DailyAvailable) {
                        $candidate.DailyTarget
                    }
                    else {
                        $null
                    }
                daily_minimum_target_records =
                    if ($dailyTargetMeta) {
                        [long]$dailyTargetMeta.Records
                    }
                    else {
                        0
                    }
                daily_target_first_date_ticks =
                    if ($dailyTargetMeta) {
                        [long]$dailyTargetMeta.FirstDateTicks
                    }
                    else {
                        0
                    }
                daily_minimum_target_last_date_ticks =
                    if ($dailyTargetMeta) {
                        [long]$dailyTargetMeta.LastDateTicks
                    }
                    else {
                        0
                    }
            }

            $stateDirty = $true
            $operationCommitted = $true
            $updated++

            $statusParts =
                New-Object System.Collections.Generic.List[string]

            if ($candidate.ScidDeferred) {
                $statusParts.Add("SCID deferred")
            }
            elseif ($candidate.ScidSkipped) {
                $statusParts.Add("SCID skipped")
            }
            elseif ($scidResult) {
                if ($scidResult.TailRecords -gt 0) {
                    $mergeLabel =
                        if ($candidate.ScidTemporaryMerge) {
                            "temporary-merge"
                        }
                        else {
                            "live-merge"
                        }

                    $scidStatus =
                        "SCID {0} source={1:N0} used={2:N0} + Rithmic={3:N0} -> out={4:N0}" -f
                        $mergeLabel,
                        $scidResult.SourceRecords,
                        $scidResult.SourceRecordsWritten,
                        $scidResult.TailRecords,
                        $scidResult.OutputRecords

                    $statusParts.Add($scidStatus)
                }
                else {
                    $scidStatus =
                        "SCID replace src={0:N0} -> out={1:N0}" -f
                        $scidResult.SourceRecords,
                        $scidResult.OutputRecords

                    $statusParts.Add($scidStatus)
                }
            }
            elseif ($targetMeta) {
                $scidStatus =
                    "SCID current={0:N0}" -f
                    $targetMeta.Records

                $statusParts.Add($scidStatus)
            }
            else {
                $statusParts.Add("SCID none")
            }

            if ($dailyResult) {
                $dailyStatus =
                    "DLY src={0:N0} applied={1:N0} kept={2:N0} replaced={3:N0} -> out={4:N0}" -f
                    $dailyResult.SourceRecords,
                    $dailyResult.SourceAppliedRecords,
                    $dailyResult.PreservedTargetRecords,
                    $dailyResult.ReplacedOrDroppedTargetRecords,
                    $dailyResult.OutputRecords

                $statusParts.Add($dailyStatus)
            }
            elseif ($dailyTargetMeta) {
                $dailyStatus =
                    "DLY current={0:N0}" -f
                    $dailyTargetMeta.Records

                $statusParts.Add($dailyStatus)
            }
            else {
                $statusParts.Add("DLY none")
            }

            $elapsed =
                if ($scidResult -and $dailyResult) {
                    $scidResult.ElapsedSeconds +
                    $dailyResult.ElapsedSeconds
                }
                elseif ($scidResult) {
                    $scidResult.ElapsedSeconds
                }
                elseif ($dailyResult) {
                    $dailyResult.ElapsedSeconds
                }
                else {
                    0
                }

            $finalStatus =
                "{0} | OK | {1} | {2:0.0}s" -f
                $statusPrefix,
                ($statusParts -join " | "),
                $elapsed

            if ($scidResult -and
                $scidResult.OutOfOrderRecords -gt 0) {
                $finalStatus +=
                    " | WARN:{0}" -f
                    $scidResult.OutOfOrderRecords
            }

            [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                $finalStatus)

            if ($scidResult) {
                $scidMode =
                    if ($candidate.ScidTemporaryMerge) {
                        "temporary-merge"
                    }
                    elseif ($scidResult.TailRecords -gt 0) {
                        "live-merge"
                    }
                    else {
                        "replace"
                    }

                $entry =
                    "SCID OK $($candidate.SourceName) -> $($candidate.TargetName) " +
                    "mode=$scidMode " +
                    "scale=x$($scales[$candidate.Group]) " +
                    "source_records=$($scidResult.SourceRecords) " +
                    "source_records_written=$($scidResult.SourceRecordsWritten) " +
                    "newer_rithmic_records=$($scidResult.TailRecords) " +
                    "handoff_datetime=$($scidResult.HandoffDateTime) " +
                    "handoff_verified_trade_seconds=$($scidResult.HandoffVerifiedTradeSeconds) " +
                    "output_records=$($scidResult.OutputRecords) " +
                    "target_bytes=$($targetMeta.Length) " +
                    "conversion_seconds=$($scidResult.ConversionSeconds) " +
                    "flush_seconds=$($scidResult.FlushSeconds) " +
                    "validation_seconds=$($scidResult.ValidationSeconds) " +
                    "replace_seconds=$($scidResult.ReplaceSeconds) " +
                    "elapsed=$($scidResult.ElapsedSeconds)"

                if ($candidate.ScidValidation) {
                    $entry +=
                        " preflight_grade=$($candidate.ScidPairGrade)" +
                        " preflight_coverage_pct=$($candidate.ScidValidation.CommonCoveragePercent)" +
                        " preflight_volume_match_pct=$($candidate.ScidValidation.VolumeMatchPercent)" +
                        " preflight_last_price_match_pct=$($candidate.ScidValidation.LastPriceMatchPercent)" +
                        " preflight_aggregate_volume_diff_pct=$($candidate.ScidValidation.AggregateVolumeDifferencePercent)"
                }

                $log.Add($entry)
                Add-Content -LiteralPath $logPath -Value $entry -Encoding UTF8

                if ($scidResult.OutOfOrderRecords -gt 0) {
                    $warningFiles++

                    $prior =
                        [SierraHistoryBridge.ScidBridge]::FormatScDateTime(
                            $scidResult.FirstPriorDateTime)

                    $offending =
                        [SierraHistoryBridge.ScidBridge]::FormatScDateTime(
                            $scidResult.FirstOutOfOrderDateTime)

                    $backSeconds =
                        $scidResult.LargestBackwardMicroseconds / 1000000.0

                    $warning =
                        "SCID WARNING $($candidate.SourceName): " +
                        "out_of_order=$($scidResult.OutOfOrderRecords) " +
                        "first_index=$($scidResult.FirstOutOfOrderIndex) " +
                        "prior=$prior offending=$offending " +
                        "largest_backward_seconds=$backSeconds " +
                        "action=preserved_record_order"

                    $log.Add($warning)
                    Add-Content -LiteralPath $logPath -Value $warning -Encoding UTF8
                }
            }

            if ($dailyResult) {
                $dailyEntry =
                    "DLY OK $($candidate.DailySourceName) -> $($candidate.DailyTargetName) " +
                    "scale=x$($scales[$candidate.Group]) " +
                    "source_records=$($dailyResult.SourceRecords) " +
                    "source_applied=$($dailyResult.SourceAppliedRecords) " +
                    "target_records_preserved=$($dailyResult.PreservedTargetRecords) " +
                    "target_records_replaced_or_dropped=$($dailyResult.ReplacedOrDroppedTargetRecords) " +
                    "latest_source_date_preserved_from_target=$($dailyResult.PreservedLatestSourceDate) " +
                    "output_records=$($dailyResult.OutputRecords) " +
                    "elapsed=$($dailyResult.ElapsedSeconds)"

                $log.Add($dailyEntry)
                Add-Content -LiteralPath $logPath -Value $dailyEntry -Encoding UTF8
            }
        }
        catch {
            $compactError = $_.Exception.Message
            if ($compactError.Length -gt 100) {
                $compactError =
                    $compactError.Substring(0, 97) + "..."
            }

            if ($_.Exception.Message.StartsWith(
                    "SOURCE_CHANGED_DURING_CONVERSION:") -or
                $_.Exception.Message.StartsWith(
                    "TARGET_CHANGED_DURING_CONVERSION:") -or
                $_.Exception.Message.StartsWith(
                    "PREFLIGHT_SNAPSHOT_CHANGED:") -or
                $_.Exception.Message.StartsWith(
                    "INSUFFICIENT_DISK_SPACE:")) {

                $runtimeDeferred++

                [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                    "$statusPrefix | DEFERRED | $compactError")

                $entry =
                    "DEFERRED $(Get-CandidateSourceDisplay $candidate) -> " +
                    "$(Get-CandidateTargetDisplay $candidate): " +
                    $_.Exception.Message

                $log.Add($entry)
                Add-Content `
                    -LiteralPath $logPath `
                    -Value $entry `
                    -Encoding UTF8
            }
            elseif ($operationCommitted) {
                $warningFiles++

                [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                    "$statusPrefix | OK | reporting warning: $compactError")

                $entry =
                    "REPORTING WARNING " +
                    "$(Get-CandidateSourceDisplay $candidate) -> " +
                    "$(Get-CandidateTargetDisplay $candidate): " +
                    $_.Exception.Message

                $log.Add($entry)
                Add-Content `
                    -LiteralPath $logPath `
                    -Value $entry `
                    -Encoding UTF8
            }
            else {
                $failed++

                [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                    "$statusPrefix | FAILED | $compactError")

                $entry =
                    "ERROR $(Get-CandidateSourceDisplay $candidate) -> " +
                    "$(Get-CandidateTargetDisplay $candidate): " +
                    $_.Exception.Message

                $log.Add($entry)
                Add-Content `
                    -LiteralPath $logPath `
                    -Value $entry `
                    -Encoding UTF8

                if ($_.ScriptStackTrace) {
                    $stackEntry =
                        "STACK " +
                        ($_.ScriptStackTrace -replace "[\r\n]+", " | ")

                    $log.Add($stackEntry)
                    Add-Content `
                        -LiteralPath $logPath `
                        -Value $stackEntry `
                        -Encoding UTF8
                }

                if ($_.InvocationInfo -and
                    $_.InvocationInfo.PositionMessage) {

                    $positionEntry =
                        "POSITION " +
                        ($_.InvocationInfo.PositionMessage -replace "[\r\n]+", " | ")

                    $log.Add($positionEntry)
                    Add-Content `
                        -LiteralPath $logPath `
                        -Value $positionEntry `
                        -Encoding UTF8
                }
            }
        }
    }

    Save-JsonFile $StatePath ([pscustomobject]@{
        sources = (Convert-HashtableToObject $stateTable)
    })

    $log | Set-Content -LiteralPath $logPath -Encoding UTF8

    $updateStopwatch.Stop()

    Write-Host
    Write-Host (
        "Done: {0} updated | {1} retired | {2} failed | {3} unchanged | {4} warning file(s) | {5:0.0}s" -f
        $updated,
        $retiredTargets,
        $failed,
        $unchanged,
        ($warningFiles + $retireWarnings),
        $updateStopwatch.Elapsed.TotalSeconds)

    $bridgePaths =
        Get-BridgePaths $resolvedDataFolder

    $archiveDirectory =
        $bridgePaths.Archive

    $storageAtEnd =
        Get-StorageSnapshot `
            $resolvedDataFolder

    $freeAtEnd = $storageAtEnd.Free

    Show-StorageDelta $storageBeforeRun $storageAtEnd

    Write-Host
    Write-Host "Log:      $logPath"
    Write-Host "Archive:  $archiveDirectory"
    Write-Host "Recovery: $backupDirectory"
    Write-Host (
        "Free:     {0}" -f
        (Format-StorageBytes $freeAtEnd))

    if (($deferredScid.Count + $runtimeDeferred) -gt 0) {
        Write-Host
        Write-Host (
            "Deferred SCID files were not replaced. Run the bridge again after " +
            "their SC Data downloads are complete.") `
            -ForegroundColor Yellow
    }

    if ($skippedLiveNames.Count -gt 0) {
        Write-Host
        Write-Host "Skipped live SCID update(s):"
        foreach ($name in $skippedLiveNames) {
            Write-Host "  $name"
        }
        Write-Host "Run the bridge again when you are ready to update them."
    }

    if ($olderSourceContracts.Count -gt 0) {
        Write-Host
        Write-Host (
            "Archive option: {0} older SC Data contract(s) are outside the bridge window and remain available to Sierra." -f
            $olderSourceContracts.Count)
        Write-Host (
            "Use Archive Historical Data / archive.cmd when you want to compress selected source contracts. Restoring returns the exact original filenames.")
    }

    switch ($sierraHandling) {
        "open-historical" {
            if ($updated -gt 0 -or $retiredTargets -gt 0) {
                Write-Host
                Write-Host (
                    "Sierra Chart remained open. For any updated chart that was " +
                    "already open, use Chart > Reload and Recalculate.")
            }
        }

        "skip-live" {
            if ($updated -gt 0 -or $retiredTargets -gt 0) {
                Write-Host
                Write-Host (
                    "Sierra Chart remained open. For any updated historical/daily " +
                    "chart that was already open, use Chart > Reload and Recalculate.")
            }
        }

        "disconnected" {
            Write-Host
            Write-Host (
                "You can reopen the affected chartbooks and use " +
                "File > Connect to Data Feed.")
        }

        "closed" {
            Write-Host
            Write-Host "You can start Sierra Chart."
        }
    }

    if ($failed -gt 0 -and
        (Test-SierraChartRunning)) {

        Write-Host
        Write-Host (
            "If a historical file failed because it was in use, close the " +
            "affected chart/chartbook and run the bridge again.") -ForegroundColor Yellow
    }

    if ($failed -gt 0) {
        return 2
    }

    return 0
}

function Invoke-SierraHistoryUtilityMode {
    Show-Banner

    if (-not (Test-Path -LiteralPath $ConverterSource)) {
        throw "ScidBridge.cs was not found next to SierraHistoryBridge.ps1."
    }

    Write-Host -NoNewline "[1/2] Engine     "
    Add-Type -Path $ConverterSource
    Write-Host "OK"

    $resolvedDataFolder =
        Get-SierraDataFolder $DataFolder

    Write-Host "[2/2] Data       $resolvedDataFolder"

    $script:CleanupDataFolder =
        $resolvedDataFolder

    [void](Start-UtilityOperationLog `
        $Mode `
        $resolvedDataFolder)

    switch ($Mode) {
        "Archive" {
            return Invoke-SourceArchiveManager `
                $resolvedDataFolder `
                ([bool]$Interactive)
        }

        "Restore" {
            return Invoke-SourceRestoreManager `
                $resolvedDataFolder `
                ([bool]$Interactive)
        }

        "Storage" {
            return Invoke-StorageReport `
                $resolvedDataFolder
        }

        default {
            throw "Unsupported utility mode: $Mode"
        }
    }
}

$exitCode = 0

try {
    if ($Mode -eq "Update") {
        $exitCode = Invoke-SierraHistoryBridge
    }
    else {
        $exitCode = Invoke-SierraHistoryUtilityMode
    }
}
catch {
    Write-Host
    Write-Host "ERROR" -ForegroundColor Red
    Write-Host $_.Exception.Message
    $exitCode = 1
}
finally {
    Stop-UtilityOperationLog

    if ($script:DeferredCleanupDirectories.Count -gt 0) {
        try {
            [void](Start-DeferredDirectoryCleanupWorker)
        }
        catch {
            Write-Host (
                "CLEANUP WARNING: could not start deferred cleanup helper: " +
                $_.Exception.Message) `
                -ForegroundColor Yellow
        }
    }

    if ($Interactive) {
        Write-Host
        Read-Host "Press Enter to close" | Out-Null
    }
}

exit $exitCode
