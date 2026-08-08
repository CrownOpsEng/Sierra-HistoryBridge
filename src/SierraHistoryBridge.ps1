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

$Version = "0.0.2"
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
            $table[$property.Name] = [string]$property.Value
        }
    }

    return $table
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

    Write-Host "[1/4] Loading SCID converter..."
    Add-Type -Path $ConverterSource
    Write-Host "      Ready."
    Write-Host

    Write-Host "[2/4] Locating Sierra Chart data..."
    $resolvedDataFolder = Get-SierraDataFolder $DataFolder
    Write-Host "      $resolvedDataFolder"

    $config = Read-JsonFile $ConfigPath
    $config | Add-Member -NotePropertyName default_data_folder -NotePropertyValue $resolvedDataFolder -Force

    if (-not $config.proven_scales) {
        $config | Add-Member -NotePropertyName proven_scales -NotePropertyValue ([pscustomobject]@{}) -Force
    }

    Write-Host
    Write-Host "[3/4] Scanning SC Data futures files..."

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

    Write-Host "      Found $($candidates.Count) SC Data futures file(s)."
    Write-Host
    Write-Host "      Verifying raw-price scale by symbol group..."

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
                    "      {0}: x{1:g} from {2} <-> {3} (median {4:N8}, {5} samples)" -f
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
                        "      {0}: using previously verified x{1:g}." -f
                        $group,
                        $scales[$group]) -ForegroundColor Yellow
                }
                else {
                    Write-Host (
                        "      {0}: no overlapping pair is available to verify the scale." -f
                        $group) -ForegroundColor Yellow
                }
            }
        }
        elseif ($scales.ContainsKey($group)) {
            Write-Host (
                "      {0}: using previously verified x{1:g}." -f
                $group,
                $scales[$group])
        }
        else {
            Write-Host (
                "      {0}: no overlapping pair is available to verify the scale." -f
                $group) -ForegroundColor Yellow
        }
    }

    $config.proven_scales = Convert-HashtableToObject $scales
    Save-JsonFile $ConfigPath $config

    $state = Read-JsonFile $StatePath
    $stateTable = Get-StateTable $state

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

        if (-not $Force -and
            (Test-Path -LiteralPath $candidate.Target) -and
            $stateTable.ContainsKey($candidate.Source) -and
            [string]($stateTable[$candidate.Source]) -eq $signature) {
            $unchanged++
            continue
        }

        $candidate | Add-Member -NotePropertyName Signature -NotePropertyValue $signature
        $ready += $candidate
    }

    Write-Host
    Write-Host "Update plan:"
    Write-Host "  Ready:      $($ready.Count)"
    Write-Host "  Unchanged:  $unchanged"
    Write-Host "  Unverified: $unverified"
    Write-Host

    foreach ($candidate in $ready) {
        if (Test-Path -LiteralPath $candidate.Target) {
            $action = "update"
        }
        else {
            $action = "create"
        }

        Write-Host (
            "  {0,-6} {1} -> {2}" -f
            $action,
            $candidate.SourceName,
            $candidate.TargetName)
    }

    if ($ready.Count -eq 0) {
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
        $response = Read-Host "Update these Rithmic history files? [Y/n]"
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
        Write-Host "Sierra Chart is running." -ForegroundColor Yellow
        Write-Host "Close all Sierra Chart instances before the files are updated."

        while (Test-SierraChartRunning) {
            Read-Host "After Sierra Chart is closed, press Enter to check again" | Out-Null
        }
    }

    Write-Host
    Write-Host "[4/4] Updating Rithmic history files..."

    $backupDirectory = Join-Path $resolvedDataFolder "SCID_Bridge_Backups"
    $logDirectory = Join-Path $resolvedDataFolder "SCID_Bridge_Logs"

    New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $logPath = Join-Path $logDirectory "bridge-$timestamp.log"
    $log = New-Object System.Collections.Generic.List[string]

    $log.Add("Sierra History Bridge v$Version")
    $log.Add("Data folder: $resolvedDataFolder")
    $log.Add("")

    $updated = 0
    $failed = 0

    for ($index = 0; $index -lt $ready.Count; $index++) {
        $candidate = $ready[$index]

        Write-Host
        Write-Host (
            "[{0}/{1}] {2} -> {3}" -f
            ($index + 1),
            $ready.Count,
            $candidate.SourceName,
            $candidate.TargetName)

        Write-Host (
            "      Source: {0:N1} MB | {1:N0} records | scale x{2:g}" -f
            ($candidate.Size / 1MB),
            $candidate.Records,
            $scales[$candidate.Group])

        try {
            $result =
                [SierraHistoryBridge.ScidBridge]::Convert(
                    $candidate.Source,
                    $candidate.Target,
                    [double]$scales[$candidate.Group],
                    $backupDirectory,
                    2.0)

            $updated++
            $stateTable[$candidate.Source] = $candidate.Signature

            Write-Host (
                "      OK: {0:N0} SC records + {1:N0} newer Rithmic records; {2:N1} s" -f
                $result.SourceRecords,
                $result.TailRecords,
                $result.ElapsedSeconds) -ForegroundColor Green

            $log.Add(
                "OK $($candidate.SourceName) -> $($candidate.TargetName) " +
                "scale=x$($scales[$candidate.Group]) " +
                "source_records=$($result.SourceRecords) " +
                "tail_records=$($result.TailRecords) " +
                "elapsed=$($result.ElapsedSeconds)")
        }
        catch {
            $failed++
            Write-Host "      ERROR: $($_.Exception.Message)" -ForegroundColor Red
            $log.Add(
                "ERROR $($candidate.SourceName) -> $($candidate.TargetName): " +
                $_.Exception.Message)
        }
    }

    Save-JsonFile $StatePath ([pscustomobject]@{
        sources = (Convert-HashtableToObject $stateTable)
    })

    $log | Set-Content -LiteralPath $logPath -Encoding UTF8

    Write-Host
    Write-Host "================================================================"
    Write-Host "Completed."
    Write-Host "  Updated: $updated"
    Write-Host "  Failed:  $failed"
    Write-Host "  Skipped unchanged: $unchanged"
    Write-Host
    Write-Host "Backups: $backupDirectory"
    Write-Host "Log:     $logPath"
    Write-Host "================================================================"

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
