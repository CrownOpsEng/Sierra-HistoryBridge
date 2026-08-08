# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [string]$DataFolder,
    [switch]$Interactive,
    [switch]$Force,
    [switch]$DryRun,
    [switch]$Yes
)

$ErrorActionPreference = "Stop"

$Version = "0.0.11"
$AppName = "SierraHistoryBridge"
$AppDataDirectory = Join-Path $env:LOCALAPPDATA $AppName
$ConfigPath = Join-Path $AppDataDirectory "config.json"
$StatePath = Join-Path $AppDataDirectory "state.json"
$SourceDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConverterSource = Join-Path $SourceDirectory "ScidBridge.cs"

New-Item -ItemType Directory -Force -Path $AppDataDirectory | Out-Null

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

    try {
        if (Test-Path -LiteralPath $Candidate.Target -PathType Leaf) {
            $targetItem =
                Get-Item -LiteralPath $Candidate.Target

            if ($targetItem.LastWriteTimeUtc -ge
                (Get-Date).ToUniversalTime().AddMinutes(-10)) {
                return $true
            }
        }
    }
    catch { }

    return $false
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
        -not $StateEntry.source_signature -or
        [string]$StateEntry.source_signature -ne $SourceSignature) {
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
            FullYear = 2000 + [int]$Year
            ContractMonth =
                Get-ContractMonth `
                    (2000 + [int]$Year) `
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

                    if ($dailyMeta.Records -gt 0) {
                        $candidate.DailyAvailable = $true
                        $candidate.DailyError = $null
                        $candidate.DailySource =
                            $file.FullName
                        $candidate.DailySourceName =
                            $file.Name
                        $candidate.DailyRecords =
                            [long]$dailyMeta.Records
                        $candidate.DailyFirstDateTicks =
                            [long]$dailyMeta.FirstDateTicks
                        $candidate.DailyLastDateTicks =
                            [long]$dailyMeta.LastDateTicks
                        $candidate.DailySize =
                            [long]$file.Length
                        $candidate.DailyModifiedTicks =
                            [long]$file.LastWriteTimeUtc.Ticks
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
    $currentMonth =
        [datetime]::new(
            (Get-Date).Year,
            (Get-Date).Month,
            1)

    $usableHistoryYears = 5
    $historyBufferMonths = 3
    $forwardBufferMonths = 6

    $windowStart =
        $currentMonth.
            AddYears(-$usableHistoryYears).
            AddMonths(-$historyBufferMonths)

    $windowEnd =
        $currentMonth.AddMonths($forwardBufferMonths)

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

    # The selected window is deliberately much shorter than the ten-year
    # Rithmic filename alias cycle. If an unusual source set still maps more
    # than one eligible contract to the same target, newest eligible wins and
    # the older candidate remains available only under its SC Data filename.
    $superseded = @()
    $selected = @()

    foreach ($targetGroup in ($candidates | Group-Object ContractKey)) {
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
        "{0} eligible contracts | {1} SCID | {2} DLY | {3} archive-only | window {4}..{5}" -f
        $candidates.Count,
        $eligibleScid,
        $eligibleDaily,
        $archiveOnly.Count,
        $windowStart.ToString("yyyy-MM"),
        $windowEnd.ToString("yyyy-MM"))

    Write-Host (
        "      Policy: 5y Sierra history + 3mo rollover buffer + 6mo forward buffer")

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

        $fullYear = 2000 + [int]$match.Groups["year"].Value
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
    $unchanged = 0
    $unverified = 0

    foreach ($candidate in $candidates) {
        if (-not $scales.ContainsKey($candidate.Group)) {
            $unverified++
            continue
        }

        $signature = $null
        $targetStatus = $null

        if ($candidate.HasScid) {
            $signature =
                "$($candidate.Size)|" +
                "$($candidate.ModifiedTicks)|" +
                "$($candidate.Last)"

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

        $dailySignature = $null
        $dailyTargetStatus = $null
        $dailyCurrent = $true

        if ($candidate.DailyAvailable) {
            $dailySignature =
                "$($candidate.DailySize)|" +
                "$($candidate.DailyModifiedTicks)|" +
                "$($candidate.DailyRecords)|" +
                "$($candidate.DailyLastDateTicks)"

            $dailyTargetStatus =
                Get-DailyTargetStatus $candidate.DailyTarget

            $dailyCurrent =
                -not $Force -and
                (Test-ProcessedDailyTargetStillValid `
                    $stateEntry `
                    $dailySignature `
                    $dailyTargetStatus)
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

        $ready += $candidate
    }

    Write-Host
    Write-Host (
        "Plan: {0} ready | {1} unchanged | {2} archive-only | {3} retire | {4} unverified" -f
        $ready.Count,
        $unchanged,
        $archiveOnly.Count,
        $retire.Count,
        $unverified)

    foreach ($candidate in $ready) {
        $scidPlan =
            if (-not $candidate.HasScid) {
                "SCID not present"
            }
            elseif ($candidate.ScidNeeded) {
                if (-not $candidate.TargetStatus.Exists) {
                    "SCID create"
                }
                elseif ($candidate.TargetStatus.Kind -eq "placeholder") {
                    "SCID replace placeholder"
                }
                else {
                    "SCID update"
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
        Write-Host
        Write-Host "Nothing needs updating."
        return 0
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

    Write-Host
    Write-Host "[4/4] Update"

    $retiredTargets = 0
    $retiredState = 0
    $retireWarnings = 0

    foreach ($item in $retire) {
        if ($item.RemoveTarget) {
            try {
                if (Test-Path -LiteralPath $item.Target -PathType Leaf) {
                    Remove-Item -LiteralPath $item.Target -Force
                    $retiredTargets++
                }

                if ($item.RemoveDailyTarget -and
                    (Test-Path -LiteralPath $item.DailyTarget -PathType Leaf)) {

                    Remove-Item -LiteralPath $item.DailyTarget -Force
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

    $backupDirectory = Join-Path $resolvedDataFolder "SCID_Bridge_Backups"
    $logDirectory = Join-Path $resolvedDataFolder "SCID_Bridge_Logs"

    New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $logPath = Join-Path $logDirectory "bridge-$timestamp.log"
    $log = New-Object System.Collections.Generic.List[string]

    $log.Add("Sierra History Bridge v$Version")
    $log.Add("Data folder: $resolvedDataFolder")
    $log.Add("Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $log.Add("")

    # Create the log before file updates begin.
    $log | Set-Content -LiteralPath $logPath -Encoding UTF8

    $updated = 0
    $failed = 0
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

        try {
            if ($candidate.ScidNeeded) {
                $scidResult =
                    [SierraHistoryBridge.ScidBridge]::Convert(
                        $candidate.Source,
                        $candidate.Target,
                        [double]$scales[$candidate.Group],
                        $backupDirectory,
                        2.0,
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
                    if ($candidate.ScidSkipped) {
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
                    if ($candidate.ScidSkipped) {
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
                    if ($candidate.ScidSkipped) {
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
                    if ($candidate.ScidSkipped) {
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

            $statusParts =
                New-Object System.Collections.Generic.List[string]

            if ($candidate.ScidSkipped) {
                $statusParts.Add("SCID skipped")
            }
            elseif ($scidResult) {
                if ($scidResult.TailRecords -gt 0) {
                    $statusParts.Add(
                        "SCID src={0:N0} + newer={1:N0} -> out={2:N0}" -f
                        $scidResult.SourceRecords,
                        $scidResult.TailRecords,
                        $scidResult.OutputRecords)
                }
                else {
                    $statusParts.Add(
                        "SCID src={0:N0} -> out={1:N0}" -f
                        $scidResult.SourceRecords,
                        $scidResult.OutputRecords)
                }
            }
            elseif ($targetMeta) {
                $statusParts.Add(
                    "SCID current={0:N0}" -f
                    $targetMeta.Records)
            }
            else {
                $statusParts.Add("SCID none")
            }

            if ($dailyResult) {
                $statusParts.Add(
                    "DLY src={0:N0} applied={1:N0} kept={2:N0} replaced={3:N0} -> out={4:N0}" -f
                    $dailyResult.SourceRecords,
                    $dailyResult.SourceAppliedRecords,
                    $dailyResult.PreservedTargetRecords,
                    $dailyResult.ReplacedOrDroppedTargetRecords,
                    $dailyResult.OutputRecords)
            }
            elseif ($dailyTargetMeta) {
                $statusParts.Add(
                    "DLY current={0:N0}" -f
                    $dailyTargetMeta.Records)
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

            $updated++

            if ($scidResult) {
                $entry =
                    "SCID OK $($candidate.SourceName) -> $($candidate.TargetName) " +
                    "scale=x$($scales[$candidate.Group]) " +
                    "source_records=$($scidResult.SourceRecords) " +
                    "newer_rithmic_records=$($scidResult.TailRecords) " +
                    "output_records=$($scidResult.OutputRecords) " +
                    "target_bytes=$($targetMeta.Length) " +
                    "conversion_seconds=$($scidResult.ConversionSeconds) " +
                    "flush_seconds=$($scidResult.FlushSeconds) " +
                    "validation_seconds=$($scidResult.ValidationSeconds) " +
                    "replace_seconds=$($scidResult.ReplaceSeconds) " +
                    "elapsed=$($scidResult.ElapsedSeconds)"

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
            $failed++

            $compactError = $_.Exception.Message
            if ($compactError.Length -gt 100) {
                $compactError = $compactError.Substring(0, 97) + "..."
            }

            [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                "$statusPrefix | FAILED | $compactError")

            $entry =
                "ERROR $(Get-CandidateSourceDisplay $candidate) -> " +
                "$(Get-CandidateTargetDisplay $candidate): " +
                $_.Exception.Message

            $log.Add($entry)
            Add-Content -LiteralPath $logPath -Value $entry -Encoding UTF8
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

    Write-Host "Log:     $logPath"
    Write-Host "Backups: $backupDirectory"

    if ($skippedLiveNames.Count -gt 0) {
        Write-Host
        Write-Host "Skipped live SCID update(s):"
        foreach ($name in $skippedLiveNames) {
            Write-Host "  $name"
        }
        Write-Host "Run the bridge again when you are ready to update them."
    }

    switch ($sierraHandling) {
        "open-historical" {
            Write-Host
            Write-Host (
                "Sierra Chart remained open. For any updated chart that was " +
                "already open, use Chart > Reload and Recalculate.")
        }

        "skip-live" {
            Write-Host
            Write-Host (
                "Sierra Chart remained open. For any updated historical/daily " +
                "chart that was already open, use Chart > Reload and Recalculate.")
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

$exitCode = 0

try {
    $exitCode = Invoke-SierraHistoryBridge
}
catch {
    Write-Host
    Write-Host "ERROR" -ForegroundColor Red
    Write-Host $_.Exception.Message
    $exitCode = 1
}
finally {
    if ($Interactive) {
        Write-Host
        Read-Host "Press Enter to close" | Out-Null
    }
}

exit $exitCode
