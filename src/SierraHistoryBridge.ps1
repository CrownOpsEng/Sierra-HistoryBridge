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

$Version = "0.0.7"
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
    Write-Host "Updates Rithmic-named Sierra Chart intraday files with SC Data"
    Write-Host "historical records while preserving newer Rithmic live records."
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
    if ($FileName.EndsWith(".scid", [StringComparison]::OrdinalIgnoreCase)) {
        return $FileName.Substring(0, $FileName.Length - 5)
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

    $sourcePattern = [regex]'^(?<root>.+?)(?<month>[FGHJKMNQUVXZ])(?<year>\d{2})-(?<exchange>[A-Za-z0-9_]+)\.scid$'
    $candidates = @()

    Get-ChildItem -LiteralPath $resolvedDataFolder -Filter "*.scid" -File |
        Sort-Object Name |
        ForEach-Object {
            $file = $_
            $match = $sourcePattern.Match($file.Name)

            if ($match.Success) {
                $root = $match.Groups["root"].Value
                $month = $match.Groups["month"].Value.ToUpperInvariant()
                $year = $match.Groups["year"].Value
                $exchange = $match.Groups["exchange"].Value.ToUpperInvariant()

                $targetName =
                    "$root$month$($year.Substring($year.Length - 1, 1)).$exchange.scid"

                $targetPath = Join-Path $resolvedDataFolder $targetName

                try {
                    $meta = [SierraHistoryBridge.ScidBridge]::GetMeta($file.FullName)

                    if ($meta.Records -gt 0) {
                        $candidates += [pscustomobject]@{
                            Source = $file.FullName
                            SourceName = $file.Name
                            Target = $targetPath
                            TargetName = $targetName
                            Group = "$($root.ToUpperInvariant())|$exchange"
                            FullYear = 2000 + [int]$year
                            MonthCode = $month
                            ContractMonth =
                                Get-ContractMonth (2000 + [int]$year) $month
                            Records = $meta.Records
                            First = $meta.FirstDateTime
                            Last = $meta.LastDateTime
                            Size = $file.Length
                            ModifiedTicks = $file.LastWriteTimeUtc.Ticks
                        }
                    }
                }
                catch {
                    Write-Host "      WARNING: skipping $($file.Name): $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
        }

    if ($candidates.Count -eq 0) {
        throw "No matching SC Data futures files were found. Expected names such as NQU26-CME.scid."
    }

    # Rithmic's one-digit year repeats every ten years. Sierra Chart also
    # limits single-digit-year Continuous Futures Contract charts to five
    # years. Treat Rithmic-named files as a rolling compatibility cache, not
    # as the canonical long-term archive.
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
    # the older candidate remains canonical only under its SC Data filename.
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
                Where-Object { $_.Source -ne $winner.Source }
        }
    }

    $candidates = $selected | Sort-Object ContractMonth, SourceName

    if ($candidates.Count -eq 0) {
        throw (
            "No SC Data contracts fall inside the current Rithmic compatibility window " +
            "($($windowStart.ToString('yyyy-MM')) through $($windowEnd.ToString('yyyy-MM'))).")
    }

    Write-Host (
        "{0} eligible | {1} archive-only | window {2}..{3}" -f
        $candidates.Count,
        $archiveOnly.Count,
        $windowStart.ToString("yyyy-MM"),
        $windowEnd.ToString("yyyy-MM"))

    Write-Host (
        "      Policy: 5y Sierra history + 3mo rollover buffer + 6mo forward buffer")

    if ($superseded.Count -gt 0) {
        Write-Host (
            "      {0} eligible source(s) superseded by newer contracts sharing a Rithmic filename." -f
            $superseded.Count) -ForegroundColor Yellow
    }

    Write-Host "      Scale verification:"

    $scales = Get-ScaleTable $config

    foreach ($group in ($candidates.Group | Sort-Object -Unique)) {
        $overlapPair = $candidates |
            Where-Object {
                $_.Group -eq $group -and (Test-Path -LiteralPath $_.Target)
            } |
            Sort-Object Last -Descending |
            Select-Object -First 1

        if ($overlapPair) {
            try {
                $inference =
                    [SierraHistoryBridge.ScidBridge]::InferScale(
                        $overlapPair.Source,
                        $overlapPair.Target)

                $scales[$group] = [double]$inference.Factor

                Write-Host (
                    "        {0,-12} x{1:g} verified | {2} <-> {3} | {5} samples" -f
                    $group,
                    $inference.Factor,
                    $overlapPair.SourceName,
                    $overlapPair.TargetName,
                    $inference.MedianRatio,
                    $inference.Samples)
            }
            catch {
                if ($scales.ContainsKey($group)) {
                    Write-Host (
                        "        {0,-12} x{1:g} saved" -f
                        $group,
                        $scales[$group]) -ForegroundColor Yellow
                }
                else {
                    Write-Host (
                        "        {0,-12} UNVERIFIED - no overlapping target" -f
                        $group) -ForegroundColor Yellow
                }
            }
        }
        elseif ($scales.ContainsKey($group)) {
            Write-Host (
                "        {0,-12} x{1:g} saved" -f
                $group,
                $scales[$group])
        }
        else {
            Write-Host (
                "        {0,-12} UNVERIFIED - no overlapping target" -f
                $group) -ForegroundColor Yellow
        }
    }

    $config.proven_scales = Convert-HashtableToObject $scales
    Save-JsonFile $ConfigPath $config

    $state = Read-JsonFile $StatePath
    $stateTable = Get-StateTable $state

    # Build a retirement plan for bridge-managed Rithmic cache files whose
    # canonical SC Data contract has rolled out of the compatibility window.
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
                Reason = "target alias reused by newer eligible contract"
            }
            continue
        }

        $targetStatus = Get-TargetStatus $targetPath

        if (-not $targetStatus.Exists) {
            $retire += [pscustomobject]@{
                Source = $sourcePath
                SourceName = $sourceName
                Target = $targetPath
                TargetName = [IO.Path]::GetFileName($targetPath)
                RemoveTarget = $false
                Reason = "managed target already missing"
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

        $retire += [pscustomobject]@{
            Source = $sourcePath
            SourceName = $sourceName
            Target = $targetPath
            TargetName = [IO.Path]::GetFileName($targetPath)
            RemoveTarget = [bool]$safeToRemove
            Reason =
                if ($safeToRemove) {
                    "outside rolling Rithmic cache window"
                }
                else {
                    "outside window but target no longer matches managed metadata"
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

        $signature =
            "$($candidate.Size)|$($candidate.ModifiedTicks)|$($candidate.Last)"

        $targetStatus = Get-TargetStatus $candidate.Target

        $candidate |
            Add-Member -NotePropertyName Signature -NotePropertyValue $signature

        $candidate |
            Add-Member -NotePropertyName TargetStatus -NotePropertyValue $targetStatus

        $stateEntry =
            if ($stateTable.ContainsKey($candidate.Source)) {
                $stateTable[$candidate.Source]
            }
            else {
                $null
            }

        if (-not $Force -and
            (Test-ProcessedTargetStillValid $stateEntry $signature $targetStatus)) {
            $unchanged++
            continue
        }

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
        $status = $candidate.TargetStatus

        if (-not $status.Exists) {
            $action = "create"
            $detail = "target missing"
        }
        elseif ($status.Kind -eq "placeholder") {
            $action = "replace"
            $detail = "header-only placeholder: $($status.Length) bytes, 0 records"
        }
        elseif ($status.Kind -eq "invalid") {
            $action = "replace"
            $detail = "existing target is not a valid SCID file"
        }
        else {
            $action = "update"
            $detail = "{0:N0} existing records, {1:N1} MB" -f
                $status.Records,
                ($status.Length / 1MB)
        }

        Write-Host (
            "  {0,-7} {1} -> {2} | {3} | {4}" -f
            $action.ToUpperInvariant(),
            (Get-CompactName $candidate.SourceName),
            (Get-CompactName $candidate.TargetName),
            (Format-CompactSize $candidate.Size),
            $detail)
    }

    foreach ($item in $retire) {
        $action =
            if ($item.RemoveTarget) { "RETIRE" } else { "STATE" }

        Write-Host (
            "  {0,-7} {1} -> {2} | {3}" -f
            $action,
            (Get-CompactName $item.SourceName),
            (Get-CompactName $item.TargetName),
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
        $response = Read-Host "Apply this Rithmic cache maintenance plan? [Y/n]"
        if (-not [string]::IsNullOrWhiteSpace($response)) {
            $normalized = $response.Trim().ToLowerInvariant()
            if ($normalized -ne "y" -and $normalized -ne "yes") {
                Write-Host "Cancelled. No files were changed."
                return 0
            }
        }
    }

    if (Test-SierraChartRunning) {
        Write-Host
        Write-Host "Sierra Chart: RUNNING - close all instances before update." -ForegroundColor Yellow

        while (Test-SierraChartRunning) {
            Read-Host "Press Enter after Sierra Chart is closed" | Out-Null
        }

        Write-Host "Sierra Chart: CLOSED"
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

                if ($stateTable.ContainsKey($item.Source)) {
                    $stateTable.Remove($item.Source)
                    $retiredState++
                }

                Write-Host (
                    "  RETIRED {0} | source {1}" -f
                    (Get-CompactName $item.TargetName),
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
        elseif ($item.Reason -eq "managed target already missing" -or
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

    # Write the log immediately so a run always leaves diagnostics even if a
    # later conversion fails or the process is interrupted.
    $log | Set-Content -LiteralPath $logPath -Encoding UTF8

    $updated = 0
    $failed = 0
    $warningFiles = 0
    $updateStopwatch = [Diagnostics.Stopwatch]::StartNew()

    for ($index = 0; $index -lt $ready.Count; $index++) {
        $candidate = $ready[$index]

        $sourceDisplay = Get-CompactName $candidate.SourceName
        $targetDisplay = Get-CompactName $candidate.TargetName
        $statusPrefix =
            "[{0}/{1}] {2} -> {3}" -f
            ($index + 1),
            $ready.Count,
            $sourceDisplay,
            $targetDisplay

        try {
            $result =
                [SierraHistoryBridge.ScidBridge]::Convert(
                    $candidate.Source,
                    $candidate.Target,
                    [double]$scales[$candidate.Group],
                    $backupDirectory,
                    2.0,
                    $statusPrefix)

            [SierraHistoryBridge.ScidBridge]::UpdateStatusLine(
                "$statusPrefix | VERIFY | checking final target")

            $targetMeta =
                [SierraHistoryBridge.ScidBridge]::GetMeta($candidate.Target)

            if ($targetMeta.Records -ne $result.OutputRecords) {
                throw (
                    "Post-replacement verification failed. Expected {0:N0} records; target contains {1:N0}." -f
                    $result.OutputRecords,
                    $targetMeta.Records)
            }

            $updated++

            $stateTable[$candidate.Source] = [pscustomobject]@{
                source_signature = $candidate.Signature
                target_path = $candidate.Target
                minimum_target_records = [long]$targetMeta.Records
                target_first_datetime = [long]$targetMeta.FirstDateTime
                minimum_target_last_datetime = [long]$targetMeta.LastDateTime
            }

            if ($result.TailRecords -gt 0) {
                $recordSummary =
                    "src={0:N0} + tail={1:N0} -> out={2:N0}" -f
                    $result.SourceRecords,
                    $result.TailRecords,
                    $result.OutputRecords
            }
            else {
                $recordSummary =
                    "src={0:N0} -> out={1:N0}" -f
                    $result.SourceRecords,
                    $result.OutputRecords
            }

            $finalStatus =
                "{0} | OK | {1} | {2:0.0}s" -f
                $statusPrefix,
                $recordSummary,
                $result.ElapsedSeconds

            if ($result.OutOfOrderRecords -gt 0) {
                $finalStatus +=
                    " | WARN:{0}" -f
                    $result.OutOfOrderRecords
            }

            [SierraHistoryBridge.ScidBridge]::CompleteStatusLine($finalStatus)

            $entry =
                "OK $($candidate.SourceName) -> $($candidate.TargetName) " +
                "scale=x$($scales[$candidate.Group]) " +
                "source_records=$($result.SourceRecords) " +
                "tail_records=$($result.TailRecords) " +
                "output_records=$($result.OutputRecords) " +
                "target_bytes=$($targetMeta.Length) " +
                "conversion_seconds=$($result.ConversionSeconds) " +
                "flush_seconds=$($result.FlushSeconds) " +
                "validation_seconds=$($result.ValidationSeconds) " +
                "replace_seconds=$($result.ReplaceSeconds) " +
                "elapsed=$($result.ElapsedSeconds)"

            $log.Add($entry)
            Add-Content -LiteralPath $logPath -Value $entry -Encoding UTF8

            if ($result.OutOfOrderRecords -gt 0) {
                $warningFiles++
                $prior =
                    [SierraHistoryBridge.ScidBridge]::FormatScDateTime(
                        $result.FirstPriorDateTime)

                $offending =
                    [SierraHistoryBridge.ScidBridge]::FormatScDateTime(
                        $result.FirstOutOfOrderDateTime)

                $backSeconds =
                    $result.LargestBackwardMicroseconds / 1000000.0

                $warning =
                    "WARNING $($candidate.SourceName): " +
                    "out_of_order=$($result.OutOfOrderRecords) " +
                    "first_index=$($result.FirstOutOfOrderIndex) " +
                    "prior=$prior offending=$offending " +
                    "largest_backward_seconds=$backSeconds " +
                    "action=preserved_record_order"

                $log.Add($warning)
                Add-Content -LiteralPath $logPath -Value $warning -Encoding UTF8
            }
        }
        catch {
            $failed++

            $compactError = $_.Exception.Message
            if ($compactError.Length -gt 90) {
                $compactError = $compactError.Substring(0, 87) + "..."
            }

            [SierraHistoryBridge.ScidBridge]::CompleteStatusLine(
                "$statusPrefix | FAILED | $compactError")

            $entry =
                "ERROR $($candidate.SourceName) -> $($candidate.TargetName): " +
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
