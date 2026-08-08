# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

# The embedded C# engine must compile with the stock Windows PowerShell 5.1
# Add-Type path. Setup, normal startup, and the self-test must all use the
# same plain Add-Type invocation.
$compatibilityScripts = @(
    (Join-Path $RepoRoot "src\SierraHistoryBridge.ps1"),
    (Join-Path $RepoRoot "scripts\Setup.ps1"),
    (Join-Path $RepoRoot "tests\Run-SelfTest.ps1")
)

foreach ($scriptPath in $compatibilityScripts) {
    $scriptText = Get-Content -LiteralPath $scriptPath -Raw

    if ($scriptText -match '(?i)-CompilerOptions|-CompilerParameters') {
        throw "Windows PowerShell 5.1 compatibility regression: custom Add-Type compiler parameters found in $scriptPath"
    }
}

$converterText = Get-Content -LiteralPath (Join-Path $RepoRoot "src\ScidBridge.cs") -Raw

if ($converterText -match '(?m)^\s*using\s+System\.Linq\s*;') {
    throw "Windows PowerShell 5.1 compatibility regression: ScidBridge.cs depends on System.Linq/System.Core."
}

if ($converterText -match '\.Distinct\s*\(') {
    throw "Windows PowerShell 5.1 compatibility regression: LINQ Distinct() found in ScidBridge.cs."
}

if ($converterText -match '(?m)\bunsafe\b|\bfixed\s*\(') {
    throw "Windows PowerShell 5.1 compatibility regression: unsafe C# found in ScidBridge.cs."
}




if ($converterText -match '\bHashSet\s*<') {
    throw "Windows PowerShell 5.1 compatibility regression: HashSet/System.Core dependency found."
}

$appText = Get-Content -LiteralPath (Join-Path $RepoRoot "src\SierraHistoryBridge.ps1") -Raw
$setupText = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\Setup.ps1") -Raw


if ($appText -match '(?m)-and\s*\r?\n\s*Test-SierraChartRunning\)') {
    throw "Sierra-running regression: command invocation is not parenthesized inside a boolean expression."
}


foreach ($requiredPolicyToken in @(
    'function Get-BridgeWindow',
    '$currentMonth.AddYears(-5).AddMonths(-3)',
    '$currentMonth.AddMonths(6)',
    'function Test-ContractInRithmicWindow',
    'older source',
    'future source',
    'outside rolling Rithmic history window'
)) {
    if ($appText -notlike "*$requiredPolicyToken*") {
        throw "Rithmic rolling-window regression: missing $requiredPolicyToken"
    }
}



if ($converterText -notmatch 'public static class DailyBridge') {
    throw "Historical Daily regression: DailyBridge is missing."
}

if ($appText -notmatch 'DailyNeeded') {
    throw "Historical Daily regression: daily update planning is missing."
}



if ($appText -notmatch 'Get-OrCreateContractCandidate') {
    throw "Discovery regression: independent SCID/DLY contract scan is missing."
}

if ($appText -notmatch 'SCID not present') {
    throw "Discovery regression: DLY-only contract handling is missing."
}

if ($converterText -notmatch 'public static ScaleInference InferScale') {
    throw "Historical Daily regression: Daily scale inference is missing."
}


if ($appText -match 'close all instances before update') {
    throw "Sierra-running regression: global shutdown requirement was reintroduced."
}

foreach ($requiredLiveToken in @(
    'Test-LiveScidCandidate',
    'Skip live SCID updates',
    'File > Disconnect',
    'Reload and Recalculate',
    'ScidSkipped'
)) {
    if ($appText -notlike "*$requiredLiveToken*") {
        throw "Sierra-running regression: missing $requiredLiveToken"
    }
}


if ($appText -match '(?s)\.Add\(\s*"[^"]+"\s*-f\s*[\r\n ]+\$[^)]*,') {
    throw "Formatting regression: a comma-separated -f expression is being passed directly to .Add(...)."
}

if ($appText -notmatch 'REPORTING WARNING') {
    throw "Reporting-safety regression: committed updates are not protected from reporting failures."
}


$dailySignatureStart =
    $appText.IndexOf(
        "function Get-DailySourceSignature",
        [StringComparison]::Ordinal)

$dailySignatureEnd =
    $appText.IndexOf(
        "function Update-DailyStateMetadata",
        $dailySignatureStart,
        [StringComparison]::Ordinal)

if ($dailySignatureStart -lt 0 -or
    $dailySignatureEnd -le $dailySignatureStart) {
    throw "Historical Daily source-signature function is missing."
}

$dailySignatureText =
    $appText.Substring(
        $dailySignatureStart,
        $dailySignatureEnd - $dailySignatureStart)

if ($dailySignatureText -match 'DailyModifiedTicks|LastWriteTimeUtc' -or
    $dailySignatureText -notmatch 'Get-FileHash') {
    throw "Historical Daily source signature must use content hashing only."
}

foreach ($dailyDirtyToken in @(
    'Get-DailySourceSignature',
    'IsSynchronized',
    'dailyStateRefreshed'
)) {
    if ($appText -notlike "*$dailyDirtyToken*") {
        throw "Historical Daily dirty-check regression: missing $dailyDirtyToken"
    }
}

if ($converterText -notmatch 'public static bool IsSynchronized') {
    throw "Historical Daily dirty-check regression: semantic comparison is missing."
}


foreach ($integrityToken in @(
    'SOURCE_CHANGED_DURING_CONVERSION',
    'TARGET_CHANGED_DURING_CONVERSION',
    'sourceRecordsWritten',
    'preserveTargetTail',
    'HandoffVerifiedTradeSeconds',
    'LIVE_MERGE_HANDOFF_UNVERIFIED',
    'LIVE_MERGE_BOUNDARY_INVALID',
    'LIVE_MERGE_TAIL_OUT_OF_ORDER',
    'SOURCE_OUT_OF_ORDER',
    'Historical replacement size validation failed',
    'Get-HistoricalScidDeferReason',
    'live-merge',
    'SCID replace'
)) {
    if ($converterText -notlike "*$integrityToken*" -and
        $appText -notlike "*$integrityToken*") {
        throw "SCID integrity requirement is missing: $integrityToken"
    }
}

if ($appText -match 'tailGuardSeconds') {
    throw "SCID integrity does not permit a fixed time-gap tail guard."
}

foreach ($preflightToken in @(
    'ValidatePair',
    'ValidateFile',
    'Get-ScidPairGrade',
    'SCID preflight validation',
    'temporary-merge',
    'Keep the Rithmic target and defer',
    'SOURCE_CHANGED_DURING_VALIDATION',
    'TARGET_CHANGED_DURING_VALIDATION',
    'rithmic-baseline.bak',
    'Get-ScidValidationReference'
)) {
    if ($converterText -notlike "*$preflightToken*" -and
        $appText -notlike "*$preflightToken*") {
        throw "SCID preflight regression: missing $preflightToken"
    }
}


foreach ($storageToken in @(
    'ArchiveScidGzipVerified',
    'ArchiveFileGzipVerified',
    'ValidatePairGzipTarget',
    'SCID_Bridge_Archive',
    'Rithmic_Baselines',
    'Rollbacks',
    'INSUFFICIENT_DISK_SPACE',
    'Finalize-ScidBackupStorage',
    'Invoke-BridgeStorageCleanup'
)) {
    if ($converterText -notlike "*$storageToken*" -and
        $appText -notlike "*$storageToken*") {
        throw "Storage regression: missing $storageToken"
    }
}

if ($appText -match 'Compress-Archive') {
    throw "Storage regression: Compress-Archive should not be used for multi-gigabyte SCID archives."
}

if ($appText -match '(?m)^\s*\$currentMonth\.\s*$') {
    throw "Windows PowerShell 5.1 regression: multiline member chaining was reintroduced."
}


foreach ($archiveManagerToken in @(
    'Resolve-FullContractYear',
    'Invoke-SourceArchiveManager',
    'Invoke-SourceRestoreManager',
    'Invoke-StorageReport',
    'Show-StorageDelta',
    'SOURCE CHANGE:',
    'CROSS-FEED',
    'MANAGED CONSISTENT',
    'Daily source quality:'
)) {
    if ($appText -notlike "*$archiveManagerToken*") {
        throw "Archive/restore regression: missing $archiveManagerToken"
    }
}

foreach ($archiveEngineToken in @(
    'GetFileAllocatedBytes',
    'RestoreFileGzipVerified',
    'HashFileSha256'
)) {
    if ($converterText -notlike "*$archiveEngineToken*") {
        throw "Archive/restore engine regression: missing $archiveEngineToken"
    }
}

if ($appText -notmatch 'Group-Object\s+TargetName') {
    throw "Rithmic alias regression: eligible contracts are not grouped by target filename."
}

if ($converterText -notmatch 'Path\.GetFileName\(sourcePath\)\s*\+\s*"__"\s*\+\s*Path\.GetFileName\(targetPath\)') {
    throw "Baseline naming regression: raw baseline does not include both source and target names."
}


if ($appText -match '(?ms)(?<!\$)\(\s*(if|foreach|for|switch|try|while|do)\b') {
    throw "PowerShell syntax regression: a statement block is being used directly inside parenthesized expression syntax."
}


foreach ($contextToken in @(
    'Wait-ForSierraChartClosed',
    'Get-BridgePaths',
    'SelectedFile',
    'SystemFileAssociations\.scid',
    'SystemFileAssociations\.dly',
    'SystemFileAssociations\.gz',
    'Sierra History Bridge storage report',
    'Configure-UserPaths'
)) {
    if ($appText -notlike "*$contextToken*" -and
        $setupText -notlike "*$contextToken*") {
        throw "Context/settings regression: missing $contextToken"
    }
}

if ($setupText -match 'Directory\\Background\\shell\\\$ProductKey"\s*`?\r?\n\s*Command') {
    throw "Explorer integration regression: global folder-background verb was reintroduced."
}


foreach ($dirtyCheckToken in @(
    'GetQuickSignature',
    'QuickConvertedPairMatches',
    'Test-LegacyScidSignatureEquivalent',
    'full SCID validation skipped by user',
    'Run full SCID validation now?'
)) {
    if ($appText -notlike "*$dirtyCheckToken*" -and
        $converterText -notlike "*$dirtyCheckToken*") {
        throw "SCID dirty-check/validation regression: missing $dirtyCheckToken"
    }
}

if ($appText -match '"\$\(\$candidate\.Size\)\|"\s*\+') {
    throw "SCID dirty-check regression: modification-time source signature was reintroduced."
}


foreach ($cleanupToken in @(
    'Remove-EmptyBridgeDirectories',
    'Invoke-BridgeDirectoryHousekeeping',
    'Get-RithmicBaselineArchives',
    'Invoke-VerifiedBaselineCleanup',
    'Verify and remove eligible baselines now?'
)) {
    if ($appText -notlike "*$cleanupToken*") {
        throw "Archive/baseline cleanup regression: missing $cleanupToken"
    }
}


foreach ($pruneToken in @(
    'Get-BridgeProtectedRootForPath',
    'Remove-EmptyParentChain',
    'Remove-BridgeOwnedFileAndPrune',
    'Refusing bridge cleanup outside configured storage roots'
)) {
    if ($appText -notlike "*$pruneToken*") {
        throw "Prune-on-delete regression: missing $pruneToken"
    }
}


foreach ($cwdCleanupToken in @(
    'Move-WorkingDirectoryOutsideTree',
    '[Environment]::CurrentDirectory',
    'Set-Location'
)) {
    if (-not $appText.Contains($cwdCleanupToken)) {
        throw "Current-directory cleanup regression: missing $cwdCleanupToken"
    }
}


foreach ($deferredCleanupToken in @(
    'Add-DeferredDirectoryCleanup',
    'Start-DeferredDirectoryCleanupWorker',
    'CLEANUP DEFERRED:',
    'cleanup-{0}.log',
    'Start-UtilityOperationLog',
    'Start-Transcript',
    'Stop-Transcript'
)) {
    if ($appText -notlike "*$deferredCleanupToken*") {
        throw "Deferred-cleanup/logging regression: missing $deferredCleanupToken"
    }
}


foreach ($flatArchiveToken in @(
    'Convert-LegacyScDataArchiveLayout',
    'Archive layout: flattened',
    '($SourceFile.Name + ".gz")'
)) {
    if ($appText -notlike "*$flatArchiveToken*") {
        throw "Flat SC_Data archive regression: missing $flatArchiveToken"
    }
}

if ($appText -match '\$safeGroup\s*=') {
    throw "Flat SC_Data archive regression: group/year archive layout was reintroduced."
}

$required = @(
    "src\SierraHistoryBridge.ps1",
    "src\ScidBridge.cs",
    "scripts\Setup.ps1",
    "scripts\Build-Release.ps1",
    "setup.cmd",
    "run.cmd",
    "archive.cmd",
    "restore.cmd",
    "storage.cmd",
    "repair.cmd",
    "uninstall.cmd",
    "README.md",
    "README.txt",
    "CHANGELOG.md",
    "CONTRIBUTING.md",
    "SECURITY.md",
    "LICENSE",
    "VERSION"
)

foreach ($relative in $required) {
    $path = Join-Path $RepoRoot $relative
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing repository file: $relative"
    }
}

$powerShellFiles =
    Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Filter "*.ps1"

foreach ($powerShellFile in $powerShellFiles) {
    $tokens = $null
    $errors = $null

    [System.Management.Automation.Language.Parser]::ParseFile(
        $powerShellFile.FullName,
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null

    if ($errors.Count -gt 0) {
        throw (
            "{0} parse error at line {1}: {2}" -f
            $powerShellFile.FullName,
            $errors[0].Extent.StartLineNumber,
            $errors[0].Message)
    }
}

$dist = Join-Path $env:TEMP ("SierraHistoryBridge-PackageTest-" + [guid]::NewGuid().ToString("N"))

try {
    & (Join-Path $RepoRoot "scripts\Build-Release.ps1") -OutputDirectory $dist

    $release = Join-Path $dist "SierraHistoryBridge"
    $releaseZip = Join-Path $dist "SierraHistoryBridge.zip"

    foreach ($relative in @(
        "app\SierraHistoryBridge.ps1",
        "app\ScidBridge.cs",
        "setup\Setup.ps1",
        "setup\payload.zip",
        "README.md",
        "README.txt",
        "setup.cmd",
        "archive.cmd",
        "restore.cmd",
        "storage.cmd",
        "repair.cmd",
        "uninstall.cmd"
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $release $relative))) {
            throw "Release package missing: $relative"
        }
    }

    if (-not (Test-Path -LiteralPath $releaseZip -PathType Leaf)) {
        throw "Release package missing: SierraHistoryBridge.zip"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($releaseZip)
    try {
        $archivePaths = @($archive.Entries | ForEach-Object { $_.FullName })

        if (@($archivePaths | Where-Object { $_.Contains('\') }).Count -gt 0) {
            throw "Release archive contains non-portable backslash entry names."
        }

        foreach ($directoryPath in @(
            "SierraHistoryBridge/",
            "SierraHistoryBridge/app/",
            "SierraHistoryBridge/docs/",
            "SierraHistoryBridge/setup/"
        )) {
            if ($archivePaths -notcontains $directoryPath) {
                throw "Release archive is missing directory entry: $directoryPath"
            }
        }

        $unexpectedRoot = @(
            $archivePaths |
                Where-Object {
                    $_ -ne "SierraHistoryBridge/" -and
                    -not $_.StartsWith("SierraHistoryBridge/")
                }
        )
        if ($unexpectedRoot.Count -gt 0) {
            throw "Release archive must contain one SierraHistoryBridge root directory."
        }

        foreach ($repositoryPath in @(
            "SierraHistoryBridge/.github/",
            "SierraHistoryBridge/scripts/",
            "SierraHistoryBridge/src/",
            "SierraHistoryBridge/tests/",
            "SierraHistoryBridge/docs/COMMIT-STANDARDS.md",
            "SierraHistoryBridge/docs/PUBLISHING.md",
            "SierraHistoryBridge/docs/VERSIONING.md",
            "SierraHistoryBridge/CONTRIBUTOR-LICENSE-AGREEMENT.md"
        )) {
            if ($archivePaths -contains $repositoryPath -or
                @($archivePaths | Where-Object { $_.StartsWith($repositoryPath) }).Count -gt 0) {
                throw "Release archive contains repository-only content: $repositoryPath"
            }
        }
    }
    finally {
        $archive.Dispose()
    }

    $payloadZip = Join-Path $release "setup\payload.zip"
    $payloadArchive = [System.IO.Compression.ZipFile]::OpenRead($payloadZip)
    try {
        $nonPortablePayloadPath = @(
            $payloadArchive.Entries |
                Where-Object { $_.FullName.Contains('\') }
        )
        if ($nonPortablePayloadPath.Count -gt 0) {
            throw "Repair payload contains non-portable backslash entry names."
        }
    }
    finally {
        $payloadArchive.Dispose()
    }

    Write-Host "PASS: repository layout"
    Write-Host "PASS: PowerShell syntax"
    Write-Host "PASS: Windows release-package build"
}
finally {
    if (Test-Path -LiteralPath $dist) {
        Remove-Item -LiteralPath $dist -Recurse -Force -ErrorAction SilentlyContinue
    }
}
