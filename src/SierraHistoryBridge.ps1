# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [string]$DataFolder,
    [ValidateSet("Update", "Archive", "Restore", "Rollback", "Storage")]
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

$Version = "0.0.29"
$AppName = "SierraHistoryBridge"
$AppDataDirectory = Join-Path $env:LOCALAPPDATA $AppName
$ConfigPath = Join-Path $AppDataDirectory "config.json"
$StatePath = Join-Path $AppDataDirectory "state.json"
$StateSchemaVersion = 1
$SourceDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConverterSource = Join-Path $SourceDirectory "ScidBridge.cs"

New-Item -ItemType Directory -Force -Path $AppDataDirectory | Out-Null

$script:DeferredCleanupDirectories = @()
$script:CleanupDataFolder = $null
$script:UtilityLogPath = $null
$script:UtilityOperation = $null
$script:UtilityStartedAt = $null
$script:EarlyUpdateDiagnostics =
    New-Object System.Collections.Generic.List[string]

function Show-Banner {
    Clear-Host
    Write-Host "================================================================"
    Write-Host " Sierra History Bridge v$Version"
    Write-Host "================================================================"
    Write-Host "Maintains Rithmic history from Sierra Chart SC Data sources."
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

function Format-LogRecord(
    [string]$Level,
    [string]$Event,
    [string]$Message) {

    $timestamp =
        Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"

    return (
        "{0} | {1,-5} | {2,-12} | {3}" -f
        $timestamp,
        $Level.ToUpperInvariant(),
        $Event.ToUpperInvariant(),
        $Message)
}

function Write-UtilityLog(
    [string]$Level,
    [string]$Event,
    [string]$Message) {

    if ([string]::IsNullOrWhiteSpace(
        $script:UtilityLogPath)) {
        return
    }

    try {
        Add-Content `
            -LiteralPath $script:UtilityLogPath `
            -Value (
                Format-LogRecord `
                    $Level `
                    $Event `
                    $Message) `
            -Encoding UTF8
    }
    catch { }
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
        Get-Date -Format "yyyyMMdd-HHmmss"

    $logPath =
        Join-Path `
            $bridgePaths.Logs `
            ("{0}-{1}.log" -f
                $Operation.ToLowerInvariant(),
                $stamp)

    try {
        $script:UtilityLogPath =
            $logPath

        $script:UtilityOperation =
            $Operation

        $script:UtilityStartedAt =
            Get-Date

        Format-LogRecord `
            "INFO" `
            "START" `
            (
                "operation={0}; version={1}; data={2}" -f
                $Operation,
                $Version,
                $ResolvedDataFolder) |
            Set-Content `
                -LiteralPath $logPath `
                -Encoding UTF8

        Write-Host "Log:       $logPath"

        return $logPath
    }
    catch {
        $script:UtilityLogPath =
            $null

        Write-Host (
            "Log warning: {0}" -f
            $_.Exception.Message) `
            -ForegroundColor Yellow

        return $null
    }
}

function Stop-UtilityOperationLog(
    [int]$ExitCode) {

    if ([string]::IsNullOrWhiteSpace(
        $script:UtilityLogPath)) {
        return
    }

    $elapsed =
        if ($script:UtilityStartedAt) {
            ((Get-Date) -
                $script:UtilityStartedAt).TotalSeconds
        }
        else {
            0
        }

    Write-UtilityLog `
        $(if ($ExitCode -eq 0) {
            "INFO"
        }
        else {
            "ERROR"
        }) `
        "END" `
        (
            "operation={0}; exit_code={1}; elapsed_seconds={2:0.000}" -f
            $script:UtilityOperation,
            $ExitCode,
            $elapsed)

    $script:UtilityLogPath =
        $null

    $script:UtilityOperation =
        $null

    $script:UtilityStartedAt =
        $null
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
        (Get-Date).ToString(
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

function New-CleanupLogLine(
    [string]$Level,
    [string]$Event,
    [string]$Message) {

    return (
        "{0} | {1,-5} | {2,-12} | {3}" -f
        (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"),
        $Level.ToUpperInvariant(),
        $Event.ToUpperInvariant(),
        $Message)
}

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
    New-CleanupLogLine `
        "INFO" `
        "START" `
        (
            "parent_pid={0}; queued_paths={1}" -f
            $parentPid,
            $items.Count)

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
                New-CleanupLogLine `
                    "INFO" `
                    "KEEP" `
                    (
                        "path={0}; reason=non_empty; items={1}" -f
                        $current,
                        $remaining.Count)
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
                New-CleanupLogLine `
                    "ERROR" `
                    "REMOVE" `
                    (
                        "path={0}; attempts=150; error={1}" -f
                        $current,
                        $lastError)
            break
        }

        $lines +=
            New-CleanupLogLine `
                "INFO" `
                "REMOVE" `
                (
                    "path={0}; status=OK" -f
                    $current)

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
    New-CleanupLogLine `
        "INFO" `
        "END" `
        "status=complete"

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
        "Cleanup deferred: locked empty folders will be retried after exit.") `
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

    $baselineDirectory =
        Join-Path `
            $archiveRoot `
            "Rithmic_Baselines"

    $rollbackDirectory =
        Join-Path `
            $archiveRoot `
            "Rollbacks"

    $flatName =
        $Candidate.SourceName +
        "__" +
        $Candidate.TargetName +
        ".gz"

    return [pscustomobject]@{
        ArchiveRoot = $archiveRoot
        BaselineDirectory = $baselineDirectory
        BaselineArchive =
            Join-Path `
                $baselineDirectory `
                $flatName
        RollbackDirectory = $rollbackDirectory
        RollbackArchive =
            Join-Path `
                $rollbackDirectory `
                $flatName
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

        if (-not $values.ContainsKey("original_name") -or
            -not $values.ContainsKey("original_bytes") -or
            -not $values.ContainsKey("records") -or
            -not $values.ContainsKey("first_datetime") -or
            -not $values.ContainsKey("last_datetime") -or
            -not $values.ContainsKey("original_write_ticks") -or
            -not $values.ContainsKey("sha256")) {

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
                [long]$values[
                    "original_write_ticks"]
            Sha256 =
                [string]$values[
                    "sha256"]
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

    $dataLogical = 0L
    $dataDisk = 0L

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

        $dataLogical +=
            [long]$file.Length

        try {
            $dataDisk +=
                [long][SierraHistoryBridge.ScidBridge]::GetFileAllocatedBytes(
                    $file.FullName)
        }
        catch {
            $dataDisk +=
                [long]$file.Length
        }

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
        DataLogical = $dataLogical
        DataDisk = $dataDisk
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
        (Format-StorageBytes $Snapshot.DataLogical),
        (Format-StorageBytes $Snapshot.DataDisk),
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
        [pscustomobject]@{ Name = "Sierra Data folder"; Before = $Before.DataDisk; After = $After.DataDisk },
        [pscustomobject]@{ Name = "Tracked total"; Before = $Before.TotalDisk; After = $After.TotalDisk },
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
        "  Logical Sierra Data: {0} -> {1} | tracked total: {2} -> {3}" -f
        (Format-StorageBytes $Before.DataLogical),
        (Format-StorageBytes $After.DataLogical),
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
            -not $values.ContainsKey("original_write_ticks") -or
            -not $values.ContainsKey("sha256")) {
            return $null
        }

        $writeTicks =
            [long]$values[
                "original_write_ticks"]

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
    $bridgePaths =
        Get-BridgePaths $DataFolder

    $directory =
        Join-Path `
            $bridgePaths.Archive `
            "SC_Data"

    return Join-Path `
        $directory `
        ($SourceFile.Name + ".gz")
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
                "  Skip {0} | validation failed" -f
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

    Write-UtilityLog `
        "INFO" `
        "PLAN" `
        (
            "operation=Archive; files={0}; contracts={1}; first_contract={2:yyyy-MM}; last_contract={3:yyyy-MM}; logical_bytes={4}; disk_bytes={5}; zero_volume_daily_files={6}" -f
            $selection.Count,
            $contractCount,
            $firstMonth,
            $lastMonth,
            $logical,
            $disk,
            $zeroVolumeFiles)

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
        $status = "Archive $($item.Name)"

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
                "$status | OK")

            Write-UtilityLog `
                "INFO" `
                "ARCHIVE" `
                (
                    "file={0}; type={1}; original_bytes={2}; archive_bytes={3}; sha256={4}; status=OK" -f
                    $item.Name,
                    $item.Extension,
                    $result.OriginalBytes,
                    $result.ArchiveBytes,
                    $result.Sha256)
        }
        catch {
            $failed++

            [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                "$status | FAILED")

            Write-UtilityLog `
                "ERROR" `
                "ARCHIVE" `
                (
                    "file={0}; type={1}; status=FAILED; error={2}" -f
                    $item.Name,
                    $item.Extension,
                    $_.Exception.Message)
        }
    }

    $emptyDirectoriesRemoved =
        Invoke-BridgeDirectoryHousekeeping `
            $ResolvedDataFolder

    $after = Get-StorageSnapshot $ResolvedDataFolder

    Write-Host
    Write-Host (
        "Archive: {0} archived | {1} failed | {2} -> {3}" -f
        $archived,
        $failed,
        (Format-StorageBytes $rawBytes),
        (Format-StorageBytes $archiveBytes))

    Show-StorageDelta $before $after

    Write-UtilityLog `
        $(if ($failed -eq 0) { "INFO" } else { "ERROR" }) `
        "SUMMARY" `
        (
            "operation=Archive; archived={0}; failed={1}; source_bytes={2}; archive_bytes={3}; empty_folders_removed={4}" -f
            $archived,
            $failed,
            $rawBytes,
            $archiveBytes,
            $emptyDirectoriesRemoved)

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
                "  Cleanup warning: could not move working directory away from " +
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
                            "  Cleanup deferred: " +
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
                "  Cleanup warning: could not remove empty folder: " +
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
            -File `
            -Filter "*.gz" `
            -ErrorAction SilentlyContinue)) {

        $meta = Read-FileArchiveMeta $archive.FullName
        if (-not $meta) {
            Write-Host (
                "  Archive warning: invalid metadata: {0}" -f
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

        if ($selection.Count -ne 1) {
            throw (
                "The selected file is not a recognized SC Data archive.")
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

    Write-UtilityLog `
        "INFO" `
        "PLAN" `
        (
            "operation=Restore; files={0}; first_contract={1:yyyy-MM}; last_contract={2:yyyy-MM}; archive_bytes={3}; restored_bytes={4}" -f
            $selection.Count,
            $firstMonth,
            $lastMonth,
            $compressedBytes,
            $rawBytes)

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
    $prunedDirectories = 0
    $conflictStamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")

    foreach ($item in $alreadyPresent) {
        try {
            $prunedDirectories +=
                Remove-BridgeOwnedFileAndPrune `
                    $item.ArchivePath `
                    $ResolvedDataFolder

            $prunedDirectories +=
                Remove-BridgeOwnedFileAndPrune `
                    $item.MetadataPath `
                    $ResolvedDataFolder `
                    -IgnoreMissing

            $deduplicated++

            Write-UtilityLog `
                "INFO" `
                "RESTORE" `
                (
                    "file={0}; status=ALREADY_CURRENT; archive_removed=true" -f
                    $item.OriginalName)
        }
        catch {
            $failed++

            Write-UtilityLog `
                "ERROR" `
                "RESTORE" `
                (
                    "file={0}; status=FAILED; phase=deduplicate; error={1}" -f
                    $item.OriginalName,
                    $_.Exception.Message)
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
                    $bridgePaths.Archive `
                    "Restore_Conflicts"

            $conflictArchive =
                Join-Path `
                    $conflictDirectory `
                    (
                        $conflictStamp +
                        "__" +
                        $item.OriginalName +
                        ".gz"
                    )

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

            Write-UtilityLog `
                "WARN" `
                "CONFLICT" `
                (
                    "file={0}; existing_destination_preserved={1}" -f
                    $item.OriginalName,
                    $conflictArchive)
        }
        catch {
            $failed++

            Write-Host (
                "  Conflict preservation failed: {0}" -f
                $item.OriginalName) `
                -ForegroundColor Red

            Write-UtilityLog `
                "ERROR" `
                "CONFLICT" `
                (
                    "file={0}; status=FAILED; error={1}" -f
                    $item.OriginalName,
                    $_.Exception.Message)
        }
    }

    foreach ($item in $pending) {
        $status = "Restore $($item.OriginalName)"
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

            $prunedDirectories +=
                Remove-BridgeOwnedFileAndPrune `
                    $item.ArchivePath `
                    $ResolvedDataFolder

            $prunedDirectories +=
                Remove-BridgeOwnedFileAndPrune `
                    $item.MetadataPath `
                    $ResolvedDataFolder `
                    -IgnoreMissing

            $restored++

            [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                "$status | OK")

            Write-UtilityLog `
                "INFO" `
                "RESTORE" `
                (
                    "file={0}; type={1}; restored_bytes={2}; sha256={3}; archive_removed=true; status=OK" -f
                    $item.OriginalName,
                    $item.Extension,
                    $result.RestoredBytes,
                    $item.Sha256)
        }
        catch {
            $failed++

            [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                "$status | FAILED")

            Write-UtilityLog `
                "ERROR" `
                "RESTORE" `
                (
                    "file={0}; type={1}; status=FAILED; error={2}" -f
                    $item.OriginalName,
                    $item.Extension,
                    $_.Exception.Message)
        }
    }

    $prunedDirectories +=
        Invoke-BridgeDirectoryHousekeeping `
            $ResolvedDataFolder

    $after = Get-StorageSnapshot $ResolvedDataFolder

    Write-Host
    Write-Host (
        "Restore: {0} restored | {1} already current | {2} conflict(s) skipped | {3} failed" -f
        $restored,
        $deduplicated,
        $skippedConflicts,
        $failed)

    Show-StorageDelta $before $after

    Write-UtilityLog `
        $(if ($failed -eq 0) { "INFO" } else { "ERROR" }) `
        "SUMMARY" `
        (
            "operation=Restore; restored={0}; already_current={1}; conflicts_skipped={2}; failed={3}; empty_folders_removed={4}" -f
            $restored,
            $deduplicated,
            $skippedConflicts,
            $failed,
            $prunedDirectories)

    if ($failed -gt 0) {
        return 2
    }

    return 0
}

function Get-RithmicTargetNameFromBackupArchive(
    [string]$ArchivePath,
    $Meta) {

    $rithmicPattern =
        [regex]'^(?<root>.+?)(?<month>[FGHJKMNQUVXZ])(?<year>\d)\.(?<exchange>[A-Za-z0-9_]+)\.(?<extension>scid|dly)$'

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

    # Composite flat backup names encode the actual Rithmic target after the
    # final "__".  Parse that explicit identity before consulting metadata.
    $separator =
        $name.LastIndexOf(
            "__",
            [StringComparison]::Ordinal)

    if ($separator -ge 0 -and
        $separator + 2 -lt $name.Length) {

        $encodedTarget =
            $name.Substring(
                $separator + 2)

        if ($rithmicPattern.IsMatch(
                $encodedTarget)) {

            return $encodedTarget
        }
    }

    if ($Meta -and
        $Meta.OriginalName) {

        $candidate =
            [IO.Path]::GetFileName(
                [string]$Meta.OriginalName)

        if ($candidate -eq
                [string]$Meta.OriginalName -and
            $rithmicPattern.IsMatch(
                $candidate)) {

            return $candidate
        }
    }

    if ($rithmicPattern.IsMatch(
            $name)) {

        return $name
    }

    return $name
}

function Get-ScDataSourceNameFromBaselineArchive(
    [string]$ArchivePath) {

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

    $separator =
        $name.IndexOf(
            "__",
            [StringComparison]::Ordinal)

    if ($separator -le 0) {
        return $null
    }

    return $name.Substring(
        0,
        $separator)
}

function Read-GzipArchiveMeta(
    [string]$ArchivePath) {

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
                $line.Substring(
                    0,
                    $separator)

            $value =
                $line.Substring(
                    $separator + 1)

            $values[$key] =
                $value
        }

        if (-not $values.ContainsKey(
                "original_name") -or
            -not $values.ContainsKey(
                "original_bytes") -or
            -not $values.ContainsKey(
                "original_write_ticks") -or
            -not $values.ContainsKey(
                "sha256")) {

            return $null
        }

        $originalName =
            [string]$values[
                "original_name"]

        return [pscustomobject]@{
            OriginalName =
                $originalName
            OriginalBytes =
                [long]$values[
                    "original_bytes"]
            OriginalWriteTicks =
                [long]$values[
                    "original_write_ticks"]
            Sha256 =
                [string]$values[
                    "sha256"]
            Records =
                if ($values.ContainsKey(
                    "records")) {

                    [long]$values[
                        "records"]
                }
                else {
                    0L
                }
            FirstDateTime =
                if ($values.ContainsKey(
                    "first_datetime")) {

                    [long]$values[
                        "first_datetime"]
                }
                else {
                    0L
                }
            LastDateTime =
                if ($values.ContainsKey(
                    "last_datetime")) {

                    [long]$values[
                        "last_datetime"]
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

function Get-RithmicBackupArchives(
    [string]$DataFolder) {

    $bridgePaths =
        Get-BridgePaths $DataFolder

    $roots =
        @(
            [pscustomobject]@{
                Kind = "baseline"
                Path =
                    Join-Path `
                        $bridgePaths.Archive `
                        "Rithmic_Baselines"
            },
            [pscustomobject]@{
                Kind = "rollback"
                Path =
                    Join-Path `
                        $bridgePaths.Archive `
                        "Rollbacks"
            }
        )

    $rithmicPattern =
        [regex]'^(?<root>.+?)(?<month>[FGHJKMNQUVXZ])(?<year>\d)\.(?<exchange>[A-Za-z0-9_]+)\.(?<extension>scid|dly)$'

    $items = @()

    foreach ($root in $roots) {
        if (-not (
            Test-Path `
                -LiteralPath $root.Path `
                -PathType Container)) {
            continue
        }

        foreach ($archive in @(
            Get-ChildItem `
                -LiteralPath $root.Path `
                -File `
                -Filter "*.gz" `
                -ErrorAction SilentlyContinue)) {

            $meta =
                Read-GzipArchiveMeta `
                    $archive.FullName

            if (-not $meta -or
                [string]::IsNullOrWhiteSpace(
                    $meta.OriginalName)) {
                continue
            }

            $targetName =
                Get-RithmicTargetNameFromBackupArchive `
                    $archive.FullName `
                    $meta

            if (-not $rithmicPattern.IsMatch(
                    $targetName)) {
                continue
            }

            $extension =
                [IO.Path]::GetExtension(
                    $targetName).TrimStart('.').ToLowerInvariant()

            $items +=
                [pscustomobject]@{
                    Kind = $root.Kind
                    ArchivePath =
                        $archive.FullName
                    MetadataPath =
                        $archive.FullName +
                        ".meta"
                    TargetName =
                        $targetName
                    TargetPath =
                        Join-Path `
                            $DataFolder `
                            $targetName
                    Extension =
                        $extension
                    OriginalBytes =
                        [long]$meta.OriginalBytes
                    OriginalWriteTicks =
                        [long]$meta.OriginalWriteTicks
                    Sha256 =
                        [string]$meta.Sha256
                    ArchiveBytes =
                        [long]$archive.Length
                    ArchiveWriteTime =
                        $archive.LastWriteTime
                }
        }
    }

    return @(
        $items |
        Sort-Object `
            ArchiveWriteTime `
            -Descending
    )
}

function Get-ExactRithmicRollbackBackup(
    [string]$DataFolder,
    [string]$TargetName,
    [long]$OriginalBytes,
    [string]$Sha256,
    [string]$ExcludeArchivePath) {

    $matches =
        @(
            Get-RithmicBackupArchives `
                $DataFolder |
            Where-Object {
                $_.Kind -eq "rollback" -and
                $_.TargetName -ieq
                    $TargetName -and
                [long]$_.OriginalBytes -eq
                    $OriginalBytes -and
                [string]$_.Sha256 -ieq
                    $Sha256 -and
                (
                    [string]::IsNullOrWhiteSpace(
                        $ExcludeArchivePath) -or
                    -not $_.ArchivePath.Equals(
                        $ExcludeArchivePath,
                        [StringComparison]::OrdinalIgnoreCase)
                )
            } |
            Sort-Object `
                ArchiveWriteTime,
                ArchivePath |
            Select-Object -First 1
        )

    if ($matches.Count -eq 0) {
        return $null
    }

    return $matches[0]
}

function Get-DuplicateRithmicRollbackBackups(
    [string]$DataFolder,
    [string]$TargetName,
    [string]$PreserveArchivePath) {

    $rollbacks =
        @(
            Get-RithmicBackupArchives `
                $DataFolder |
            Where-Object {
                $_.Kind -eq "rollback" -and
                (
                    [string]::IsNullOrWhiteSpace(
                        $TargetName) -or
                    $_.TargetName -ieq
                        $TargetName
                )
            }
        )

    if ($rollbacks.Count -lt 2) {
        return [pscustomobject]@{
            Groups = @()
            GroupCount = 0
            RedundantCount = 0
            ReclaimableBytes = 0L
        }
    }

    $groupTable = @{}

    foreach ($item in $rollbacks) {
        $key =
            (
                $item.TargetName.ToUpperInvariant() +
                "|" +
                ([string][long]$item.OriginalBytes) +
                "|" +
                $item.Sha256.ToUpperInvariant()
            )

        if (-not $groupTable.ContainsKey(
                $key)) {

            $groupTable[$key] =
                New-Object System.Collections.Generic.List[object]
        }

        $groupTable[$key].Add(
            $item)
    }

    $duplicateGroups =
        New-Object System.Collections.Generic.List[object]

    $redundantCount = 0
    $reclaimableBytes = 0L

    foreach ($key in $groupTable.Keys) {
        $items =
            @(
                $groupTable[$key] |
                Sort-Object `
                    ArchiveWriteTime,
                    ArchivePath
            )

        if ($items.Count -lt 2) {
            continue
        }

        $keeper = $null

        if (-not [string]::IsNullOrWhiteSpace(
                $PreserveArchivePath)) {

            $keeperMatch =
                @(
                    $items |
                    Where-Object {
                        $_.ArchivePath.Equals(
                            $PreserveArchivePath,
                            [StringComparison]::OrdinalIgnoreCase)
                    } |
                    Select-Object -First 1
                )

            if ($keeperMatch.Count -gt 0) {
                $keeper =
                    $keeperMatch[0]
            }
        }

        if (-not $keeper) {
            $keeper =
                $items[0]
        }

        $duplicates =
            @(
                $items |
                Where-Object {
                    -not $_.ArchivePath.Equals(
                        $keeper.ArchivePath,
                        [StringComparison]::OrdinalIgnoreCase)
                }
            )

        $groupReclaimable = 0L

        foreach ($duplicate in $duplicates) {
            $groupReclaimable +=
                [long]$duplicate.ArchiveBytes

            if (Test-Path `
                -LiteralPath $duplicate.MetadataPath `
                -PathType Leaf) {

                $groupReclaimable +=
                    [long](
                        Get-Item `
                            -LiteralPath $duplicate.MetadataPath).Length
            }
        }

        $duplicateGroups.Add(
            [pscustomobject]@{
                TargetName =
                    $keeper.TargetName
                OriginalBytes =
                    [long]$keeper.OriginalBytes
                Sha256 =
                    [string]$keeper.Sha256
                Count =
                    $items.Count
                Keeper =
                    $keeper
                Duplicates =
                    $duplicates
                ReclaimableBytes =
                    $groupReclaimable
            })

        $redundantCount +=
            $duplicates.Count

        $reclaimableBytes +=
            $groupReclaimable
    }

    return [pscustomobject]@{
        Groups =
            @($duplicateGroups)
        GroupCount =
            $duplicateGroups.Count
        RedundantCount =
            $redundantCount
        ReclaimableBytes =
            $reclaimableBytes
    }
}

function Clear-ConfirmedRithmicRollbackDuplicates(
    [string]$DataFolder,
    $DuplicateReport) {

    $removed = 0
    $reclaimed = 0L
    $warnings = 0

    foreach ($group in @(
        $DuplicateReport.Groups)) {

        foreach ($duplicate in @(
            $group.Duplicates)) {

            try {
                $bytes =
                    [long]$duplicate.ArchiveBytes

                if (Test-Path `
                    -LiteralPath $duplicate.MetadataPath `
                    -PathType Leaf) {

                    $bytes +=
                        [long](
                            Get-Item `
                                -LiteralPath $duplicate.MetadataPath).Length
                }

                [void](Remove-BridgeOwnedFileAndPrune `
                    $duplicate.ArchivePath `
                    $DataFolder)

                [void](Remove-BridgeOwnedFileAndPrune `
                    $duplicate.MetadataPath `
                    $DataFolder `
                    -IgnoreMissing)

                $removed++
                $reclaimed +=
                    $bytes
            }
            catch {
                $warnings++

                Write-UtilityLog `
                    "WARN" `
                    "DUPLICATE" `
                    (
                        "target={0}; archive={1}; action=KEEP; error={2}" -f
                        $group.TargetName,
                        $duplicate.ArchivePath,
                        $_.Exception.Message)
            }
        }
    }

    return [pscustomobject]@{
        Removed = $removed
        ReclaimedBytes = $reclaimed
        Warnings = $warnings
    }
}

function Review-RithmicRollbackDuplicates(
    [string]$DataFolder,
    [string]$TargetName,
    [string]$PreserveArchivePath,
    [bool]$AskToClear) {

    $report =
        Get-DuplicateRithmicRollbackBackups `
            $DataFolder `
            $TargetName `
            $PreserveArchivePath

    if ($report.GroupCount -eq 0) {
        return [pscustomobject]@{
            Found = $false
            Cleared = $false
            Groups = 0
            Redundant = 0
            Removed = 0
            ReclaimedBytes = 0L
            Warnings = 0
        }
    }

    Write-Host
    Write-Host "Duplicate rollback backups:"

    foreach ($group in $report.Groups) {
        Write-Host (
            "  {0} | {1} identical copies | {2} redundant" -f
            $group.TargetName,
            $group.Count,
            (Format-StorageBytes `
                $group.ReclaimableBytes))

        Write-UtilityLog `
            "WARN" `
            "DUPLICATE" `
            (
                "target={0}; copies={1}; redundant={2}; reclaimable_bytes={3}; keeper={4}; duplicates={5}" -f
                $group.TargetName,
                $group.Count,
                $group.Duplicates.Count,
                $group.ReclaimableBytes,
                $group.Keeper.ArchivePath,
                (($group.Duplicates |
                    ForEach-Object {
                        $_.ArchivePath
                    }) -join " | "))
    }

    Write-Host (
        "  Total: {0} group(s) | {1} redundant backup(s) | {2} reclaimable" -f
        $report.GroupCount,
        $report.RedundantCount,
        (Format-StorageBytes `
            $report.ReclaimableBytes))

    $clear =
        $false

    if ($Yes) {
        $clear =
            $true
    }
    elseif ($AskToClear) {
        $answer =
            Read-Host (
                "Remove redundant copies, keeping one verified backup per exact state? [y/N]")

        $clear =
            $answer.Trim().ToLowerInvariant() -in @(
                "y",
                "yes")
    }

    if (-not $clear) {
        Write-Host "  Duplicates left unchanged."

        return [pscustomobject]@{
            Found = $true
            Cleared = $false
            Groups = $report.GroupCount
            Redundant = $report.RedundantCount
            Removed = 0
            ReclaimedBytes = 0L
            Warnings = 0
        }
    }

    $result =
        Clear-ConfirmedRithmicRollbackDuplicates `
            $DataFolder `
            $report

    Write-Host (
        "  Removed {0} redundant backup(s) | {1} reclaimed" -f
        $result.Removed,
        (Format-StorageBytes `
            $result.ReclaimedBytes))

    Write-UtilityLog `
        $(if ($result.Warnings -eq 0) {
            "INFO"
        }
        else {
            "WARN"
        }) `
        "CLEANUP" `
        (
            "duplicate_rollbacks_removed={0}; reclaimed_bytes={1}; warnings={2}" -f
            $result.Removed,
            $result.ReclaimedBytes,
            $result.Warnings)

    return [pscustomobject]@{
        Found = $true
        Cleared = $true
        Groups = $report.GroupCount
        Redundant = $report.RedundantCount
        Removed = $result.Removed
        ReclaimedBytes = $result.ReclaimedBytes
        Warnings = $result.Warnings
    }
}


function Invalidate-BridgeStateForRithmicTarget(
    [string]$TargetPath,
    [string]$Extension) {

    $state =
        Read-JsonFile `
            $StatePath

    $table =
        Get-StateTable `
            $state

    $changed = $false

    foreach ($key in @($table.Keys)) {
        $entry =
            $table[$key]

        if ($null -eq $entry -or
            $entry -is [string]) {
            continue
        }

        if ($Extension -eq "scid" -and
            $entry.target_path -and
            [string]$entry.target_path -ieq
                $TargetPath) {

            $table.Remove(
                $key)

            $changed = $true
            continue
        }

        if ($Extension -eq "dly" -and
            $entry.daily_target_path -and
            [string]$entry.daily_target_path -ieq
                $TargetPath) {

            foreach ($propertyName in @(
                "daily_source_signature",
                "daily_target_path",
                "daily_minimum_target_records",
                "daily_target_first_date_ticks",
                "daily_minimum_target_last_date_ticks"
            )) {
                if ($entry.PSObject.Properties[
                    $propertyName]) {

                    $entry.PSObject.Properties.Remove(
                        $propertyName)
                }
            }

            $table[$key] =
                $entry

            $changed = $true
        }
    }

    if ($changed) {
        Save-JsonFile `
            $StatePath `
            ([pscustomobject]@{
                schema_version =
                    $StateSchemaVersion
                sources =
                    (Convert-HashtableToObject `
                        $table)
            })
    }

    return $changed
}

function New-RithmicUndoArchive(
    $Backup,
    [string]$DataFolder) {

    if (-not (
        Test-Path `
            -LiteralPath $Backup.TargetPath `
            -PathType Leaf)) {

        return $null
    }

    $bridgePaths =
        Get-BridgePaths $DataFolder

    $stamp =
        (Get-Date).ToString(
            "yyyyMMdd-HHmmss-fff")

    $directory =
        Join-Path `
            $bridgePaths.Archive `
            "Rollbacks"

    $archivePath =
        Join-Path `
            $directory `
            (
                "manual-" +
                $stamp +
                "__" +
                $Backup.TargetName +
                ".gz"
            )

    if ($Backup.Extension -eq "scid") {
        [SierraHistoryBridge.ScidBridge]::ArchiveScidGzipVerified(
            $Backup.TargetPath,
            $archivePath,
            $false,
            $false) | Out-Null
    }
    else {
        [SierraHistoryBridge.ScidBridge]::ArchiveFileGzipVerified(
            $Backup.TargetPath,
            $archivePath,
            $false,
            $false) | Out-Null
    }

    return $archivePath
}

function Invoke-RithmicRollbackManager(
    [string]$ResolvedDataFolder,
    [bool]$AskForSelection) {

    Set-Location `
        -LiteralPath $ResolvedDataFolder

    [Environment]::CurrentDirectory =
        $ResolvedDataFolder

    $backups =
        Get-RithmicBackupArchives `
            $ResolvedDataFolder

    if ($backups.Count -eq 0) {
        Write-Host
        Write-Host "No Rithmic backup archives are available."
        return 0
    }

    $selection = $null

    if ($SelectedFile) {
        $selectedPath =
            [IO.Path]::GetFullPath(
                $SelectedFile.Trim().Trim('"'))

        $matches =
            @(
                $backups |
                Where-Object {
                    $_.ArchivePath.Equals(
                        $selectedPath,
                        [StringComparison]::OrdinalIgnoreCase)
                }
            )

        if ($matches.Count -ne 1) {
            throw (
                "The selected file is not a recognized Rithmic backup.")
        }

        $selection =
            $matches[0]
    }
    elseif ($AskForSelection) {
        Write-Host
        Write-Host "Rithmic backups:"

        for ($index = 0;
            $index -lt $backups.Count;
            $index++) {

            $item =
                $backups[$index]

            Write-Host (
                "  [{0}] {1,-9} {2,-18} {3,10} | {4}" -f
                ($index + 1),
                $item.Kind,
                $item.TargetName,
                (Format-StorageBytes `
                    $item.ArchiveBytes),
                $item.ArchiveWriteTime.ToString(
                    "yyyy-MM-dd HH:mm:ss"))
        }

        Write-Host
        $answer =
            Read-Host "Backup number to roll back, or Enter to cancel"

        if ([string]::IsNullOrWhiteSpace(
            $answer)) {
            return 0
        }

        $number = 0

        if (-not [int]::TryParse(
            $answer,
            [ref]$number) -or
            $number -lt 1 -or
            $number -gt $backups.Count) {

            throw "Invalid backup selection."
        }

        $selection =
            $backups[
                $number - 1]
    }
    else {
        throw (
            "Rollback requires -SelectedFile or interactive selection.")
    }

    if (-not (Wait-ForSierraChartClosed `
            "Rolling back Rithmic data" `
            $AskForSelection)) {
        return 0
    }

    $duplicateReview =
        Review-RithmicRollbackDuplicates `
            $ResolvedDataFolder `
            $selection.TargetName `
            $(if ($selection.Kind -eq "rollback") {
                $selection.ArchivePath
            }
            else {
                $null
            }) `
            ([bool]$AskForSelection)

    # Refresh inventory after any user-confirmed cleanup.
    $backups =
        Get-RithmicBackupArchives `
            $ResolvedDataFolder

    $targetExists =
        Test-Path `
            -LiteralPath $selection.TargetPath `
            -PathType Leaf

    $alreadyMatches = $false
    $targetHash = $null
    $targetLength = 0L
    $existingUndo = $null

    if ($targetExists) {
        try {
            $targetHash =
                [SierraHistoryBridge.ScidBridge]::HashFileSha256(
                    $selection.TargetPath)

            $targetLength =
                [long](
                    Get-Item `
                        -LiteralPath $selection.TargetPath).Length

            $alreadyMatches =
                $targetLength -eq
                    [long]$selection.OriginalBytes -and
                $targetHash -ieq
                    [string]$selection.Sha256
        }
        catch {
            $alreadyMatches = $false
            $targetHash = $null
            $targetLength = 0L
        }

        if ($targetHash) {
            $existingUndo =
                Get-ExactRithmicRollbackBackup `
                    $ResolvedDataFolder `
                    $selection.TargetName `
                    $targetLength `
                    $targetHash `
                    $null
        }
    }

    Write-Host
    Write-Host "Rollback plan:"
    Write-Host "  Backup: $($selection.ArchivePath)"
    Write-Host "  Type:   $($selection.Kind)"
    Write-Host "  Target: $($selection.TargetPath)"
    Write-Host (
        "  Size:   {0}" -f
        (Format-StorageBytes `
            $selection.OriginalBytes))

    if ($alreadyMatches) {
        Write-Host
        Write-Host (
            "Target already matches this backup. No rollback is required.")
        return 0
    }

    if ($targetExists -and $existingUndo) {
        Write-Host (
            "  Safety: current target already has a verified rollback backup.")
    }
    elseif ($targetExists) {
        Write-Host (
            "  Safety: current target will be preserved before replacement.")
    }
    else {
        Write-Host (
            "  Safety: target is missing; the selected backup will recreate it.")
    }

    Write-Host (
        "  Backup retention: selected backup is kept after rollback.")

    Write-UtilityLog `
        "INFO" `
        "PLAN" `
        (
            "operation=Rollback; kind={0}; backup={1}; target={2}; original_bytes={3}; target_exists={4}; target_already_matches={5}; existing_undo={6}" -f
            $selection.Kind,
            $selection.ArchivePath,
            $selection.TargetPath,
            $selection.OriginalBytes,
            $targetExists,
            $alreadyMatches,
            $(if ($existingUndo) { $existingUndo.ArchivePath } else { "none" }))

    if ($DryRun) {
        Write-Host
        Write-Host "Dry run: no files were changed."
        return 0
    }

    if (-not $Yes) {
        $answer =
            Read-Host (
                "Roll back $($selection.TargetName) from this backup? [y/N]")

        if ($answer.Trim().ToLowerInvariant() -notin @(
            "y",
            "yes")) {

            Write-Host "Rollback canceled."
            return 0
        }
    }

    $requiredBytes =
        [long]$selection.OriginalBytes +
        256MB

    $freeBytes =
        Get-AvailableFreeBytes `
            $ResolvedDataFolder

    if ($freeBytes -ge 0 -and
        $freeBytes -lt $requiredBytes) {

        throw (
            "Insufficient free space for verified rollback. Need about " +
            (Format-StorageBytes $requiredBytes) +
            "; available " +
            (Format-StorageBytes $freeBytes) +
            ".")
    }

    $before =
        Get-StorageSnapshot `
            $ResolvedDataFolder

    $undoArchive = $null
    $undoReused = $false

    if ($targetExists) {
        Write-Host

        if ($existingUndo) {
            $undoArchive =
                $existingUndo.ArchivePath

            $undoReused =
                $true

            Write-Host (
                "Using existing undo backup: $undoArchive")
        }
        else {
            Write-Host (
                "Preserving current target before rollback...")

            $undoArchive =
                New-RithmicUndoArchive `
                    $selection `
                    $ResolvedDataFolder

            $duplicateUndo =
                Get-ExactRithmicRollbackBackup `
                    $ResolvedDataFolder `
                    $selection.TargetName `
                    $targetLength `
                    $targetHash `
                    $undoArchive

            if ($duplicateUndo) {
                $postCreateReview =
                    Review-RithmicRollbackDuplicates `
                        $ResolvedDataFolder `
                        $selection.TargetName `
                        $duplicateUndo.ArchivePath `
                        ([bool]$AskForSelection)

                if ($postCreateReview.Cleared) {
                    $undoArchive =
                        $duplicateUndo.ArchivePath

                    $undoReused =
                        $true

                    Write-Host (
                        "Using existing undo backup: $undoArchive")
                }
                else {
                    Write-Host (
                        "Undo backup: $undoArchive")
                }
            }
            else {
                Write-Host (
                    "Undo backup: $undoArchive")
            }
        }

        Write-UtilityLog `
            "INFO" `
            "UNDO" `
            (
                "target={0}; backup={1}; reused={2}; status=OK" -f
                $selection.TargetPath,
                $undoArchive,
                $undoReused)
    }

    $status =
        "Rollback $($selection.TargetName)"

    try {
        [SierraHistoryBridge.ScidBridge]::UpdateStatusLine(
            $status)

        $isScid =
            $selection.Extension -eq
            "scid"

        $result =
            [SierraHistoryBridge.ScidBridge]::RestoreFileGzipVerified(
                $selection.ArchivePath,
                $selection.TargetPath,
                [long]$selection.OriginalBytes,
                [string]$selection.Sha256,
                [long]$selection.OriginalWriteTicks,
                [bool]$isScid,
                [bool]$targetExists)

        [void](Invalidate-BridgeStateForRithmicTarget `
            $selection.TargetPath `
            $selection.Extension)

        [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
            "$status | OK")

        Write-UtilityLog `
            "INFO" `
            "ROLLBACK" `
            (
                "target={0}; backup={1}; restored_bytes={2}; sha256={3}; replace_existing={4}; undo_backup={5}; undo_reused={6}; state_invalidated=true; status=OK" -f
                $selection.TargetName,
                $selection.ArchivePath,
                $result.RestoredBytes,
                $selection.Sha256,
                $targetExists,
                $(if ($undoArchive) { $undoArchive } else { "none" }),
                $undoReused)
    }
    catch {
        [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
            "$status | FAILED")

        Write-UtilityLog `
            "ERROR" `
            "ROLLBACK" `
            (
                "target={0}; backup={1}; status=FAILED; error={2}" -f
                $selection.TargetName,
                $selection.ArchivePath,
                $_.Exception.Message)

        throw
    }

    $after =
        Get-StorageSnapshot `
            $ResolvedDataFolder

    Write-Host
    Write-Host (
        "Rollback complete: {0}" -f
        $selection.TargetName)

    Write-Host (
        "Selected backup retained: {0}" -f
        $selection.ArchivePath)

    if ($undoArchive) {
        Write-Host (
            "Undo backup retained:     {0}" -f
            $undoArchive)
    }

    Write-Host (
        "Bridge state for the restored target was invalidated; the next Update will re-evaluate it.")

    Show-StorageDelta `
        $before `
        $after

    Write-UtilityLog `
        "INFO" `
        "SUMMARY" `
        (
            "operation=Rollback; target={0}; selected_backup_retained=true; undo_backup={1}; undo_reused={2}" -f
            $selection.TargetName,
            $(if ($undoArchive) { $undoArchive } else { "none" }),
            $undoReused)

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

    if (-not (
        Test-Path `
            -LiteralPath $root `
            -PathType Container)) {

        return @()
    }

    $items = @()

    foreach ($archive in @(
        Get-ChildItem `
            -LiteralPath $root `
            -File `
            -Filter "*.scid.gz" `
            -ErrorAction SilentlyContinue)) {

        $meta =
            Read-ScidArchiveMeta `
                $archive.FullName

        if (-not $meta) {
            continue
        }

        $sourceName =
            Get-ScDataSourceNameFromBaselineArchive `
                $archive.FullName

        $targetName =
            Get-RithmicTargetNameFromBackupArchive `
                $archive.FullName `
                (Read-GzipArchiveMeta `
                    $archive.FullName)

        if ([string]::IsNullOrWhiteSpace(
                $sourceName) -or
            [string]::IsNullOrWhiteSpace(
                $targetName)) {

            continue
        }

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
                ArchivePath =
                    $archive.FullName
                MetadataPath =
                    $archive.FullName +
                    ".meta"
                SourceName =
                    $sourceName
                SourcePath =
                    Join-Path `
                        $DataFolder `
                        $sourceName
                TargetName =
                    $targetName
                TargetPath =
                    Join-Path `
                        $DataFolder `
                        $targetName
                Group =
                    $group
                ArchiveBytes =
                    [long]$archive.Length
                Meta =
                    $meta
            }
    }

    return @(
        $items |
        Sort-Object `
            SourceName,
            TargetName
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
        "Independent Rithmic baselines used for cross-feed validation.")

    Write-UtilityLog `
        "INFO" `
        "BASELINES" `
        (
            "count={0}; archive_bytes={1}" -f
            $baselines.Count,
            $totalBytes)

    if ($Ask -and -not $Yes) {
        Write-Host (
            "Removing them requires one final full source-vs-baseline validation.")
        Write-Host (
            "Only fully covered STRONG matches are removed.")

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
    $prunedDirectories = 0

    foreach ($item in $baselines) {
        $status =
            "Baseline $($item.TargetName)"

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
                    "  Keep {0} | source or target unavailable" -f
                    $item.TargetName) `
                    -ForegroundColor Yellow

                Write-UtilityLog `
                    "WARN" `
                    "BASELINE" `
                    (
                        "source={0}; target={1}; status=KEPT; reason=source_or_target_unavailable" -f
                        $item.SourceName,
                        $item.TargetName)

                continue
            }

            if (-not $scales.ContainsKey($item.Group)) {
                $kept++
                Write-Host (
                    "  Keep {0} | no verified price scale for {1}" -f
                    $item.TargetName,
                    $item.Group) `
                    -ForegroundColor Yellow

                Write-UtilityLog `
                    "WARN" `
                    "BASELINE" `
                    (
                        "source={0}; target={1}; status=KEPT; reason=missing_price_scale; group={2}" -f
                        $item.SourceName,
                        $item.TargetName,
                        $item.Group)

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
                    "  Keep {0} | SC Data does not fully cover baseline" -f
                    $item.TargetName) `
                    -ForegroundColor Yellow

                Write-UtilityLog `
                    "WARN" `
                    "BASELINE" `
                    (
                        "source={0}; target={1}; status=KEPT; reason=incomplete_source_coverage" -f
                        $item.SourceName,
                        $item.TargetName)

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
                    "  Keep {0} | target does not match converted SC Data" -f
                    $item.TargetName) `
                    -ForegroundColor Yellow

                Write-UtilityLog `
                    "WARN" `
                    "BASELINE" `
                    (
                        "source={0}; target={1}; status=KEPT; reason=current_target_mismatch" -f
                        $item.SourceName,
                        $item.TargetName)

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
                    "$status | Keep | $grade")

                $kept++

                Write-UtilityLog `
                    "WARN" `
                    "BASELINE" `
                    (
                        "source={0}; target={1}; status=KEPT; reason=validation_grade; grade={2}; source_out_of_order={3}; target_out_of_order={4}" -f
                        $item.SourceName,
                        $item.TargetName,
                        $grade,
                        $validation.SourceOutOfOrderRecords,
                        $validation.TargetOutOfOrderRecords)

                continue
            }

            if ($DryRun) {
                [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                    "$status | Verified | dry run")

                $kept++

                Write-UtilityLog `
                    "INFO" `
                    "BASELINE" `
                    (
                        "source={0}; target={1}; status=VERIFIED; action=dry_run; grade={2}" -f
                        $item.SourceName,
                        $item.TargetName,
                        $grade)

                continue
            }

            $bytes =
                [long](
                    Get-Item `
                        -LiteralPath $item.ArchivePath).Length

            $prunedDirectories +=
                Remove-BridgeOwnedFileAndPrune `
                    $item.ArchivePath `
                    $ResolvedDataFolder

            $prunedDirectories +=
                Remove-BridgeOwnedFileAndPrune `
                    $item.MetadataPath `
                    $ResolvedDataFolder `
                    -IgnoreMissing

            $removed++
            $reclaimed += $bytes

            [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                "$status | REMOVED")

            Write-UtilityLog `
                "INFO" `
                "BASELINE" `
                (
                    "source={0}; target={1}; status=REMOVED; archive_bytes={2}; grade={3}" -f
                    $item.SourceName,
                    $item.TargetName,
                    $bytes,
                    $grade)
        }
        catch {
            $failed++

            try {
                [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                    "$status | FAILED")
            }
            catch { }

            Write-UtilityLog `
                "ERROR" `
                "BASELINE" `
                (
                    "source={0}; target={1}; status=FAILED; error={2}" -f
                    $item.SourceName,
                    $item.TargetName,
                    $_.Exception.Message)
        }
    }

    $prunedDirectories +=
        Invoke-BridgeDirectoryHousekeeping `
            $ResolvedDataFolder

    Write-Host
    Write-Host (
        "Baseline cleanup: {0} removed | {1} kept | {2} failed | reclaimed {3}" -f
        $removed,
        $kept,
        $failed,
        (Format-StorageBytes $reclaimed))

    Write-UtilityLog `
        $(if ($failed -eq 0) { "INFO" } else { "ERROR" }) `
        "BASELINES" `
        (
            "removed={0}; kept={1}; failed={2}; reclaimed_bytes={3}; empty_folders_removed={4}" -f
            $removed,
            $kept,
            $failed,
            $reclaimed,
            $prunedDirectories)

    if ($failed -gt 0) {
        return 2
    }

    return 0
}

function Invoke-StorageReport([string]$ResolvedDataFolder) {

    $snapshot =
        Get-StorageSnapshot `
            $ResolvedDataFolder

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
        [pscustomobject]@{ Name = "Sierra Data folder"; Logical = $snapshot.DataLogical; Disk = $snapshot.DataDisk },
        [pscustomobject]@{ Name = "Tracked total"; Logical = $snapshot.TotalLogical; Disk = $snapshot.TotalDisk }
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
    Write-Host "  Recovery staging: $($snapshot.RecoveryPath)"
    Write-Host "  Logs:     $($snapshot.LogPath)"

    Write-UtilityLog `
        "INFO" `
        "SNAPSHOT" `
        (
            "sources_logical={0}; sources_disk={1}; rithmic_logical={2}; rithmic_disk={3}; archive_logical={4}; archive_disk={5}; recovery_logical={6}; recovery_disk={7}; logs_logical={8}; logs_disk={9}; other_logical={10}; other_disk={11}; data_logical={12}; data_disk={13}; tracked_logical={14}; tracked_disk={15}; free_bytes={16}" -f
            $snapshot.SourcesLogical,
            $snapshot.SourcesDisk,
            $snapshot.RithmicLogical,
            $snapshot.RithmicDisk,
            $snapshot.ArchiveLogical,
            $snapshot.ArchiveDisk,
            $snapshot.RecoveryLogical,
            $snapshot.RecoveryDisk,
            $snapshot.LogsLogical,
            $snapshot.LogsDisk,
            $snapshot.OtherLogical,
            $snapshot.OtherDisk,
            $snapshot.DataLogical,
            $snapshot.DataDisk,
            $snapshot.TotalLogical,
            $snapshot.TotalDisk,
            $snapshot.Free)

    $rithmicBackups =
        Get-RithmicBackupArchives `
            $ResolvedDataFolder

    if ($rithmicBackups.Count -gt 0) {
        $baselineBackupCount =
            @(
                $rithmicBackups |
                Where-Object {
                    $_.Kind -eq "baseline"
                }
            ).Count

        $rollbackBackupCount =
            @(
                $rithmicBackups |
                Where-Object {
                    $_.Kind -eq "rollback"
                }
            ).Count


        $rithmicBackupBytes =
            [long]((
                $rithmicBackups |
                Measure-Object `
                    -Property ArchiveBytes `
                    -Sum).Sum)

        Write-Host
        Write-Host (
            "Rithmic backups: {0} baseline | {1} rollback | {2} on disk" -f
            $baselineBackupCount,
            $rollbackBackupCount,
            (Format-StorageBytes `
                $rithmicBackupBytes))
    }

    [void](Review-RithmicRollbackDuplicates `
        $ResolvedDataFolder `
        $null `
        $null `
        ([bool]$Interactive))

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
    $staleTemps = 0
    $warnings = 0

    $duplicateReport =
        Get-DuplicateRithmicRollbackBackups `
            $DataFolder `
            $null `
            $null

    # Reclaim abandoned conversion/output files before scanning market data.
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

    $emptyDirectories =
        Invoke-BridgeDirectoryHousekeeping `
            $DataFolder

    $recoveryFiles =
        if (Test-Path `
            -LiteralPath $backupDirectory `
            -PathType Container) {

            @(
                Get-ChildItem `
                    -LiteralPath $backupDirectory `
                    -File `
                    -ErrorAction SilentlyContinue
            ).Count
        }
        else {
            0
        }

    return [pscustomobject]@{
        ReclaimedBytes = $reclaimed
        StaleTemps = $staleTemps
        DuplicateRollbackGroups = $duplicateReport.GroupCount
        DuplicateRollbackFiles = $duplicateReport.RedundantCount
        DuplicateRollbackBytes = $duplicateReport.ReclaimableBytes
        RecoveryFiles = $recoveryFiles
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
                        "Baseline {0}" -f
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
                            "Rollback backup {0}" -f
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

    $rawBaselinePath =
        if (Test-Path `
            -LiteralPath $baselinePath `
            -PathType Leaf) {

            $baselinePath
        }
        else {
            $null
        }

    if ($rawBaselinePath) {
        try {
            $status =
                "Baseline {0}" -f
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
                "$status | OK")

            $script:EarlyUpdateDiagnostics.Add(
                (
                    Format-LogRecord `
                        "INFO" `
                        "BASELINE" `
                        (
                            "target={0}; original_bytes={1}; archive_bytes={2}; sha256={3}; status=OK" -f
                            $Candidate.TargetName,
                            $archiveResult.OriginalBytes,
                            $archiveResult.ArchiveBytes,
                            $archiveResult.Sha256)))

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
                "Baseline $($Candidate.TargetName) | WARNING")

            $script:EarlyUpdateDiagnostics.Add(
                (
                    Format-LogRecord `
                        "WARN" `
                        "BASELINE" `
                        (
                            "target={0}; status=WARNING; error={1}" -f
                            $Candidate.TargetName,
                            $_.Exception.Message)))
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

    if ($null -eq $State -or
        -not $State.PSObject.Properties["schema_version"] -or
        [int]$State.schema_version -ne
            $StateSchemaVersion -or
        -not $State.sources) {

        return $table
    }

    foreach ($property in
        $State.sources.PSObject.Properties) {

        if ($property.Value -is
            [pscustomobject]) {

            $table[$property.Name] =
                $property.Value
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

function Update-ScidStateMetadata(
    $StateEntry,
    $Candidate,
    [string]$SourceSignature,
    $TargetStatus) {

    if ($null -eq $StateEntry -or
        $StateEntry -isnot [pscustomobject]) {

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

    if ($StateEntry -isnot [pscustomobject]) {
        return $false
    }

    if ($null -eq $StateEntry -or
        -not $StateEntry.source_signature) {
        return $false
    }

    $savedSignature =
        [string]$StateEntry.source_signature

    if ($savedSignature -ne $SourceSignature) {
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
    $script:EarlyUpdateDiagnostics.Clear()

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

    $duplicateReview =
        $null

    if ($storageCleanup.DuplicateRollbackFiles -gt 0) {
        $duplicateReview =
            Review-RithmicRollbackDuplicates `
                $resolvedDataFolder `
                $null `
                $null `
                ([bool]$Interactive)

        $duplicateStatus =
            Get-DuplicateRithmicRollbackBackups `
                $resolvedDataFolder `
                $null `
                $null

        $storageCleanup.DuplicateRollbackGroups =
            $duplicateStatus.GroupCount

        $storageCleanup.DuplicateRollbackFiles =
            $duplicateStatus.RedundantCount

        $storageCleanup.DuplicateRollbackBytes =
            $duplicateStatus.ReclaimableBytes

        $script:EarlyUpdateDiagnostics.Add(
            (
                Format-LogRecord `
                    "INFO" `
                    "DUPLICATE" `
                    (
                        "groups={0}; redundant={1}; reclaimable_bytes={2}; removed={3}; user_confirmed={4}" -f
                        $duplicateReview.Groups,
                        $duplicateReview.Redundant,
                        $(if ($duplicateReview.Cleared) {
                            $duplicateReview.ReclaimedBytes
                        }
                        else {
                            $storageCleanup.DuplicateRollbackBytes
                        }),
                        $duplicateReview.Removed,
                        $duplicateReview.Cleared)))
    }

    $freeAfterCleanup =
        Get-AvailableFreeBytes `
            $resolvedDataFolder

    $storageAfterCleanup =
        Get-StorageSnapshot `
            $resolvedDataFolder

    Write-Host (
        "      Storage: {0} free | {1} on disk" -f
        (Format-StorageBytes $freeAfterCleanup),
        (Format-StorageBytes $storageAfterCleanup.DataDisk))

    if ($storageCleanup.StaleTemps -gt 0 -or
        $storageCleanup.EmptyDirectories -gt 0 -or
        $storageCleanup.ReclaimedBytes -gt 0) {

        Write-Host (
            "      Cleanup: {0} stale temp | {1} empty folder | {2} reclaimed" -f
            $storageCleanup.StaleTemps,
            $storageCleanup.EmptyDirectories,
            (Format-StorageBytes `
                $storageCleanup.ReclaimedBytes))
    }

    if ($storageCleanup.RecoveryFiles -gt 0) {
        Write-Host (
            "      Recovery staging: {0} file(s)" -f
            $storageCleanup.RecoveryFiles) `
            -ForegroundColor Yellow
    }

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
        "      Window: 5y history + 3mo rollover + 6mo forward")

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

    Write-Host "      Price scale:"

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
                    "        {0,-12} x{1:g} SCID | {2} <-> {3} | {4} samples" -f
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

    # Surface a source disappearance recorded by saved state.
    # This is informational and never changes the surviving target.
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
                "      Source change: {0} is missing; existing target left unchanged." -f
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

            # If state is missing or stale, compare the actual Daily source
            # and target before deciding that a rewrite is necessary.
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
                        "Validate {0} <-> {1}" -f
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

                    [SierraHistoryBridge.ScidBridge]::UpdateStatusLine(
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
                        "Validate $(Get-CandidateSourceDisplay $candidate) | DEFERRED")

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
                        "Validate {0}" -f
                        (Get-CandidateSourceDisplay $candidate)

                    $candidate.ScidFileValidation =
                        [SierraHistoryBridge.ScidBridge]::ValidateFile(
                            $candidate.Source,
                            $fileValidationPrefix)

                    [SierraHistoryBridge.ScidBridge]::UpdateStatusLine(
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
                        "Validate $(Get-CandidateSourceDisplay $candidate) | DEFERRED")

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
            (
                Format-LogRecord `
                    "INFO" `
                    "START" `
                    (
                        "operation=Preflight; version={0}; data={1}" -f
                        $Version,
                        $resolvedDataFolder)))

        $preflightOutput.Add(
            (
                Format-LogRecord `
                    "INFO" `
                    "THRESHOLDS" `
                    "strong_coverage_pct=99; strong_volume_match_pct=98; strong_last_price_match_pct=99; max_aggregate_volume_diff_pct=0.5"))

        foreach ($line in $preflightLines) {
            $preflightOutput.Add(
                (
                    Format-LogRecord `
                        "INFO" `
                        "CHECK" `
                        $line))
        }

        $preflightOutput.Add(
            (
                Format-LogRecord `
                    "INFO" `
                    "SUMMARY" `
                    (
                        "checks={0}; decisions={1}" -f
                        $preflightLines.Count,
                        $decisionCandidates.Count)))

        $preflightOutput |
            Set-Content `
                -LiteralPath $preflightLogPath `
                -Encoding UTF8

        [SierraHistoryBridge.ScidBridge]::ClearStatusLine()

        Write-Host
        Write-Host (
            "Preflight: {0} SCID check(s) | {1} decision(s)" -f
            $preflightLines.Count,
            $decisionCandidates.Count)

        Write-Host "  Log: $preflightLogPath"
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

                        "SCID replace"
                    }
                    else {
                        "SCID replace"
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
            "  Update  {0} -> {1} | {2} | {3}" -f
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
                "  Defer   {0} -> {1} | SCID | {2}" -f
                (Get-CandidateSourceDisplay $candidate),
                (Get-CandidateTargetDisplay $candidate),
                $candidate.ScidDeferReason) `
                -ForegroundColor Yellow
        }
    }

    foreach ($item in $retire) {
        $action =
            if ($item.RemoveTarget) { "Retire" } else { "State" }

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
                ([pscustomobject]@{
                    schema_version =
                        $StateSchemaVersion
                    sources =
                        (Convert-HashtableToObject `
                            $stateTable)
                })
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

    $liveValidationLogEntries =
        New-Object System.Collections.Generic.List[string]

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
                    "Validate live {0} <-> {1}" -f
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

                $liveValidationLogEntries.Add(
                    (
                        Format-LogRecord `
                            "INFO" `
                            "LIVE-CHECK" `
                            (
                                "source={0}; target={1}; grade={2}; coverage_pct={3}; volume_match_pct={4}; last_price_match_pct={5}; aggregate_volume_diff_pct={6}; source_out_of_order={7}; target_out_of_order={8}" -f
                                $candidate.SourceName,
                                $candidate.TargetName,
                                $candidate.ScidPairGrade,
                                $candidate.ScidValidation.CommonCoveragePercent,
                                $candidate.ScidValidation.VolumeMatchPercent,
                                $candidate.ScidValidation.LastPriceMatchPercent,
                                $candidate.ScidValidation.AggregateVolumeDifferencePercent,
                                $candidate.ScidValidation.SourceOutOfOrderRecords,
                                $candidate.ScidValidation.TargetOutOfOrderRecords)))

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

                        $liveValidationLogEntries.Add(
                            (
                                Format-LogRecord `
                                    "WARN" `
                                    "LIVE-CHECK" `
                                    (
                                        "source={0}; target={1}; action=DEFER; reason=validation_review" -f
                                        $candidate.SourceName,
                                        $candidate.TargetName)))
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
                    "  Defer {0} | validation failed" -f
                    (Get-CandidateTargetDisplay $candidate)) `
                    -ForegroundColor Yellow

                $liveValidationLogEntries.Add(
                    (
                        Format-LogRecord `
                            "WARN" `
                            "LIVE-CHECK" `
                            (
                                "source={0}; target={1}; action=DEFER; error={2}" -f
                                $candidate.SourceName,
                                $candidate.TargetName,
                                $_.Exception.Message)))
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

    $retireLogEntries =
        New-Object System.Collections.Generic.List[string]

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
                    "  Retired {0} | {1}" -f
                    (Get-CompactName $item.TargetName),
                    $retiredTypes)

                $retireLogEntries.Add(
                    (
                        Format-LogRecord `
                            "INFO" `
                            "RETIRE" `
                            (
                                "source={0}; target={1}; files={2}; status=OK" -f
                                $item.SourceName,
                                $item.TargetName,
                                $retiredTypes)))
            }
            catch {
                $retireWarnings++
                Write-Host (
                    "  Retire warning {0}" -f
                    (Get-CompactName $item.TargetName)) `
                    -ForegroundColor Yellow

                $retireLogEntries.Add(
                    (
                        Format-LogRecord `
                            "WARN" `
                            "RETIRE" `
                            (
                                "source={0}; target={1}; status=FAILED; error={2}" -f
                                $item.SourceName,
                                $item.TargetName,
                                $_.Exception.Message)))
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
                "  Retire skipped {0}" -f
                (Get-CompactName $item.TargetName)) `
                -ForegroundColor Yellow

            $retireLogEntries.Add(
                (
                    Format-LogRecord `
                        "WARN" `
                        "RETIRE" `
                        (
                            "source={0}; target={1}; status=SKIPPED; reason={2}" -f
                            $item.SourceName,
                            $item.TargetName,
                            $item.Reason)))
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

    $log.Add(
        (
            Format-LogRecord `
                "INFO" `
                "START" `
                (
                    "operation=Update; version={0}; data={1}; ready={2}; deferred={3}; unchanged={4}; retire={5}" -f
                    $Version,
                    $resolvedDataFolder,
                    $ready.Count,
                    $deferredScid.Count,
                    $unchanged,
                    $retire.Count)))

    $log.Add(
        (
            Format-LogRecord `
                "INFO" `
                "STORAGE" `
                (
                    "free_bytes={0}; data_logical={1}; data_disk={2}; stale_temp_removed={3}; duplicate_rollback_groups={4}; duplicate_rollback_files={5}; duplicate_rollback_bytes={6}; empty_folders_removed={7}; recovery_files={8}; reclaimed_bytes={9}" -f
                    $freeAfterCleanup,
                    $storageAfterCleanup.DataLogical,
                    $storageAfterCleanup.DataDisk,
                    $storageCleanup.StaleTemps,
                    $storageCleanup.DuplicateRollbackGroups,
                    $storageCleanup.DuplicateRollbackFiles,
                    $storageCleanup.DuplicateRollbackBytes,
                    $storageCleanup.EmptyDirectories,
                    $storageCleanup.RecoveryFiles,
                    $storageCleanup.ReclaimedBytes)))

    if ($preflightLogPath) {
        $log.Add(
            (
                Format-LogRecord `
                    "INFO" `
                    "PREFLIGHT" `
                    (
                        "report={0}; checks={1}; decisions={2}" -f
                        $preflightLogPath,
                        $preflightLines.Count,
                        $decisionCandidates.Count)))
    }

    foreach ($line in $preflightLines) {
        $log.Add(
            (
                Format-LogRecord `
                    "INFO" `
                    "PREFLIGHT" `
                    $line))
    }

    foreach ($entry in $script:EarlyUpdateDiagnostics) {
        $log.Add(
            $entry)
    }

    foreach ($entry in $liveValidationLogEntries) {
        $log.Add(
            $entry)
    }

    foreach ($entry in $retireLogEntries) {
        $log.Add(
            $entry)
    }

    # Create the log before file updates begin.
    $log |
        Set-Content `
            -LiteralPath $logPath `
            -Encoding UTF8

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
                    "$statusPrefix | Verify SCID")

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
                        Format-LogRecord `
                            "WARN" `
                            "STORAGE" `
                            (
                                "file={0}; status=WARNING; error={1}" -f
                                $candidate.TargetName,
                                $storageResult.Warning)

                    $log.Add($storageEntry)
                    Add-Content `
                        -LiteralPath $logPath `
                        -Value $storageEntry `
                        -Encoding UTF8
                }
                elseif ($storageResult.Archived -or
                    $storageResult.Pruned) {

                    $storageEntry =
                        Format-LogRecord `
                            "INFO" `
                            "STORAGE" `
                            (
                                "file={0}; reclaimed_bytes={1}" -f
                                $candidate.TargetName,
                                $storageResult.SavedBytes)

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
                    "$statusPrefix | Update DLY")

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
                            Format-LogRecord `
                                "INFO" `
                                "STORAGE" `
                                (
                                    "file={0}; reclaimed_bytes={1}" -f
                                    $candidate.DailyTargetName,
                                    $dailySaved)

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
                        Format-LogRecord `
                            "WARN" `
                            "STORAGE" `
                            (
                                "file={0}; status=WARNING; error={1}" -f
                                $candidate.DailyTargetName,
                                $_.Exception.Message)

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
                $statusParts.Add(
                    "SCID deferred")
            }
            elseif ($candidate.ScidSkipped) {
                $statusParts.Add(
                    "SCID skipped")
            }
            elseif ($scidResult) {
                if ($candidate.ScidTemporaryMerge) {
                    $statusParts.Add(
                        "SCID temporary merge")
                }
                elseif ($scidResult.TailRecords -gt 0) {
                    $statusParts.Add(
                        "SCID live merge")
                }
                else {
                    $statusParts.Add(
                        "SCID updated")
                }
            }
            elseif ($targetMeta) {
                $statusParts.Add(
                    "SCID current")
            }

            if ($dailyResult) {
                $statusParts.Add(
                    "DLY updated")
            }
            elseif ($dailyTargetMeta) {
                $statusParts.Add(
                    "DLY current")
            }

            $elapsed =
                if ($scidResult -and
                    $dailyResult) {

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
                ($statusParts -join " + "),
                $elapsed

            if ($scidResult -and
                $scidResult.OutOfOrderRecords -gt 0) {

                $finalStatus +=
                    " | warning"
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

                $entryMessage =
                    "source=$($candidate.SourceName); target=$($candidate.TargetName); " +
                    "mode=$scidMode; " +
                    "scale=x$($scales[$candidate.Group]); " +
                    "source_records=$($scidResult.SourceRecords); " +
                    "source_records_written=$($scidResult.SourceRecordsWritten); " +
                    "rithmic_tail_records=$($scidResult.TailRecords); " +
                    "handoff_datetime=$($scidResult.HandoffDateTime); " +
                    "handoff_verified_trade_seconds=$($scidResult.HandoffVerifiedTradeSeconds); " +
                    "output_records=$($scidResult.OutputRecords); " +
                    "target_bytes=$($targetMeta.Length); " +
                    "conversion_seconds=$($scidResult.ConversionSeconds); " +
                    "flush_seconds=$($scidResult.FlushSeconds); " +
                    "validation_seconds=$($scidResult.ValidationSeconds); " +
                    "replace_seconds=$($scidResult.ReplaceSeconds); " +
                    "elapsed_seconds=$($scidResult.ElapsedSeconds)"

                if ($candidate.ScidValidation) {
                    $entryMessage +=
                        "; preflight_grade=$($candidate.ScidPairGrade)" +
                        "; preflight_coverage_pct=$($candidate.ScidValidation.CommonCoveragePercent)" +
                        "; preflight_volume_match_pct=$($candidate.ScidValidation.VolumeMatchPercent)" +
                        "; preflight_last_price_match_pct=$($candidate.ScidValidation.LastPriceMatchPercent)" +
                        "; preflight_aggregate_volume_diff_pct=$($candidate.ScidValidation.AggregateVolumeDifferencePercent)"
                }

                $entry =
                    Format-LogRecord `
                        "INFO" `
                        "SCID" `
                        $entryMessage

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
                        Format-LogRecord `
                            "WARN" `
                            "SCID" `
                            (
                                "source={0}; out_of_order_records={1}; first_index={2}; prior={3}; offending={4}; largest_backward_seconds={5}; action=preserve_record_order" -f
                                $candidate.SourceName,
                                $scidResult.OutOfOrderRecords,
                                $scidResult.FirstOutOfOrderIndex,
                                $prior,
                                $offending,
                                $backSeconds)

                    $log.Add($warning)
                    Add-Content -LiteralPath $logPath -Value $warning -Encoding UTF8
                }
            }

            if ($dailyResult) {
                $dailyEntry =
                    Format-LogRecord `
                        "INFO" `
                        "DLY" `
                        (
                            "source={0}; target={1}; scale=x{2}; source_records={3}; source_applied={4}; target_records_preserved={5}; target_records_replaced_or_dropped={6}; latest_source_date_preserved_from_target={7}; output_records={8}; elapsed_seconds={9}" -f
                            $candidate.DailySourceName,
                            $candidate.DailyTargetName,
                            $scales[$candidate.Group],
                            $dailyResult.SourceRecords,
                            $dailyResult.SourceAppliedRecords,
                            $dailyResult.PreservedTargetRecords,
                            $dailyResult.ReplacedOrDroppedTargetRecords,
                            $dailyResult.PreservedLatestSourceDate,
                            $dailyResult.OutputRecords,
                            $dailyResult.ElapsedSeconds)

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
                    "$statusPrefix | DEFERRED")

                $entry =
                    Format-LogRecord `
                        "WARN" `
                        "DEFER" `
                        (
                            "source={0}; target={1}; error={2}" -f
                            (Get-CandidateSourceDisplay $candidate),
                            (Get-CandidateTargetDisplay $candidate),
                            $_.Exception.Message)

                $log.Add($entry)
                Add-Content `
                    -LiteralPath $logPath `
                    -Value $entry `
                    -Encoding UTF8
            }
            elseif ($operationCommitted) {
                $warningFiles++

                [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                    "$statusPrefix | OK | log warning")

                $entry =
                    Format-LogRecord `
                        "WARN" `
                        "REPORTING" `
                        (
                            "source={0}; target={1}; error={2}" -f
                            (Get-CandidateSourceDisplay $candidate),
                            (Get-CandidateTargetDisplay $candidate),
                            $_.Exception.Message)

                $log.Add($entry)
                Add-Content `
                    -LiteralPath $logPath `
                    -Value $entry `
                    -Encoding UTF8
            }
            else {
                $failed++

                [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                    "$statusPrefix | FAILED")

                $entry =
                    Format-LogRecord `
                        "ERROR" `
                        "UPDATE" `
                        (
                            "source={0}; target={1}; error={2}" -f
                            (Get-CandidateSourceDisplay $candidate),
                            (Get-CandidateTargetDisplay $candidate),
                            $_.Exception.Message)

                $log.Add($entry)
                Add-Content `
                    -LiteralPath $logPath `
                    -Value $entry `
                    -Encoding UTF8

                if ($_.ScriptStackTrace) {
                    $stackEntry =
                        Format-LogRecord `
                            "ERROR" `
                            "STACK" `
                            ($_.ScriptStackTrace -replace "[

]+", " | ")

                    $log.Add($stackEntry)
                    Add-Content `
                        -LiteralPath $logPath `
                        -Value $stackEntry `
                        -Encoding UTF8
                }

                if ($_.InvocationInfo -and
                    $_.InvocationInfo.PositionMessage) {

                    $positionEntry =
                        Format-LogRecord `
                            "ERROR" `
                            "POSITION" `
                            ($_.InvocationInfo.PositionMessage -replace "[

]+", " | ")

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
        schema_version = $StateSchemaVersion
        sources = (Convert-HashtableToObject $stateTable)
    })

    $updateStopwatch.Stop()

    $log.Add(
        (
            Format-LogRecord `
                $(if ($failed -eq 0) { "INFO" } else { "ERROR" }) `
                "SUMMARY" `
                (
                    "updated={0}; retired={1}; failed={2}; unchanged={3}; warnings={4}; runtime_deferred={5}; elapsed_seconds={6:0.000}" -f
                    $updated,
                    $retiredTargets,
                    $failed,
                    $unchanged,
                    ($warningFiles + $retireWarnings),
                    $runtimeDeferred,
                    $updateStopwatch.Elapsed.TotalSeconds)))

    $log |
        Set-Content `
            -LiteralPath $logPath `
            -Encoding UTF8

    Write-Host
    Write-Host (
        "Complete: {0} updated | {1} retired | {2} failed | {3} unchanged | {4} warning(s) | {5:0.0}s" -f
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
    Write-Host "Recovery staging: $backupDirectory"
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
            "Use Archive SC Data or archive.cmd to move selected source contracts offline.")
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

        "Rollback" {
            return Invoke-RithmicRollbackManager `
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
    Write-Host "Error" -ForegroundColor Red
    Write-Host $_.Exception.Message

    Write-UtilityLog `
        "ERROR" `
        "ERROR" `
        $_.Exception.ToString()

    $exitCode = 1
}
finally {
    Stop-UtilityOperationLog `
        $exitCode

    if ($script:DeferredCleanupDirectories.Count -gt 0) {
        try {
            [void](Start-DeferredDirectoryCleanupWorker)
        }
        catch {
            Write-Host (
                "Cleanup warning: could not start deferred cleanup helper: " +
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
