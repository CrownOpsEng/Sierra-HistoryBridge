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

if ($appText -notmatch '"REPORTING"') {
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

if ($dailySignatureText -match 'ModifiedTicks|LastWriteTime|\.Ticks') {
    throw "Historical Daily source signature must not use modification time."
}

foreach ($dailySignatureToken in @(
    'Get-FileHash',
    '-Algorithm SHA256',
    'sha256:'
)) {
    if ($dailySignatureText -notlike "*$dailySignatureToken*") {
        throw "Historical Daily source-signature requirement is missing: $dailySignatureToken"
    }
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
    'Test-ScidPreflightSnapshotCurrent',
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
    'HistoryBridge',
    'Baselines',
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

if ($converterText -notmatch 'Path\.GetFileName\(sourcePath\)\s*\+\s*"--"\s*\+\s*Path\.GetFileName\(targetPath\)') {
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
    'Storage Report',
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
    '$StateSchemaVersion = 1',
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


foreach ($loggingToken in @(
    'Format-LogRecord',
    'Write-UtilityLog',
    'Start-UtilityOperationLog',
    'Start-DeferredDirectoryCleanupWorker',
    'cleanup-{0}.log'
)) {
    if ($appText -notlike "*$loggingToken*") {
        throw "Logging regression: missing $loggingToken"
    }
}

if ($appText -match 'Start-Transcript|Stop-Transcript') {
    throw "Logging regression: PowerShell transcript logging was reintroduced."
}

foreach ($flatArchiveToken in @(
    'Get-SourceArchivePath',
    'Get-RithmicTargetNameFromBackupArchive',
    'Get-ScDataSourceNameFromBaselineArchive',
    'Baselines',
    'Rollbacks',
    'RestoreConflicts'
)) {
    if ($appText -notlike "*$flatArchiveToken*") {
        throw "Flat archive regression: missing $flatArchiveToken"
    }
}

if ($appText -notmatch '\$StateSchemaVersion\s*=\s*1') {
    throw "State regression: schema version 1 is not defined."
}

if ($appText -notmatch 'schema_version\s*=\s*\$StateSchemaVersion') {
    throw "State regression: state saves are not schema-versioned."
}

foreach ($rollbackToken in @(
    'Invoke-RithmicRollbackManager',
    'Get-RithmicBackupArchives',
    'New-RithmicUndoArchive',
    'Invalidate-BridgeStateForRithmicTarget',
    'Selected backups retained'
)) {
    if ($appText -notlike "*$rollbackToken*") {
        throw "Rithmic rollback regression: missing $rollbackToken"
    }
}

$modeValidateSet =
    [regex]::Match(
        $appText,
        '(?s)\[ValidateSet\((?<values>[^)]*)\)\]\s*\[string\]\$Mode')

if (-not $modeValidateSet.Success) {
    throw "Mode ValidateSet is missing."
}

$modeValues =
    $modeValidateSet.Groups['values'].Value

foreach ($requiredMode in @(
    'Update',
    'Archive',
    'Restore',
    'Rollback',
    'Storage',
    'Explorer'
)) {
    if ($modeValues -notmatch ('"' + [regex]::Escape($requiredMode) + '"')) {
        throw "Mode ValidateSet must include $requiredMode."
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot "rollback.cmd") -PathType Leaf)) {
    throw "Rithmic rollback regression: rollback.cmd is missing."
}

foreach ($menuText in @(
    'Update History',
    'Storage Report',
    'Archive SC Data',
    'Restore SC Data',
    'Rollback Rithmic'
)) {
    if ($setupText -notlike "*$menuText*") {
        throw "Explorer-menu regression: missing concise menu text: $menuText"
    }
}

foreach ($storageToken in @(
    'DataLogical',
    'DataDisk',
    'Tracked total'
)) {
    if ($appText -notlike "*$storageToken*") {
        throw "Storage-report regression: missing $storageToken"
    }
}

$archivePathFunctionStart =
    $appText.IndexOf('function Get-ScidArchivePaths')

$archivePathFunctionEnd =
    $appText.IndexOf('function Read-ScidArchiveMeta')

$archivePathFunction =
    $appText.Substring(
        $archivePathFunctionStart,
        $archivePathFunctionEnd - $archivePathFunctionStart)

if ($archivePathFunction -like '*$sourceStem*' -or
    $archivePathFunction -like '*FullYear*') {
    throw "Flat archive regression: nested Rithmic archive paths were reintroduced."
}

if ($appText -match 'Join-Path\s+`\s*\r?\n\s+\$directory\s+`\s*\r?\n\s+"Manual"') {
    throw "Flat archive regression: a Manual rollback subdirectory was reintroduced."
}

$licenseText =
    Get-Content `
        -LiteralPath (Join-Path $RepoRoot "LICENSE") `
        -Raw

if ($licenseText -notmatch 'Mozilla Public License Version 2.0' -or
    $licenseText -notmatch '2.1. Grants') {
    throw "License regression: the official MPL 2.0 text is missing."
}

foreach ($licenseReference in @(
    "README.md",
    "README.txt",
    "CONTRIBUTING.md"
)) {
    $licenseReferenceText =
        Get-Content -LiteralPath (Join-Path $RepoRoot $licenseReference) -Raw

    if ($licenseReferenceText -notmatch 'Mozilla Public License 2.0') {
        throw "License regression: $licenseReference does not identify MPL 2.0."
    }
}

foreach ($sourceFile in @(
    Get-ChildItem -LiteralPath (Join-Path $RepoRoot "src") -File -Recurse
    Get-ChildItem -LiteralPath (Join-Path $RepoRoot "scripts") -File -Recurse
    Get-ChildItem -LiteralPath (Join-Path $RepoRoot "tests") -File -Recurse
    Get-ChildItem -LiteralPath $RepoRoot -File -Filter "*.cmd"
)) {
    $sourceText = Get-Content -LiteralPath $sourceFile.FullName -Raw
    if ($sourceText -notmatch 'SPDX-License-Identifier: MPL-2.0') {
        throw "License regression: missing MPL SPDX notice in $($sourceFile.FullName)."
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot "docs\RELEASE.md"))) {
    throw "Documentation regression: release guide is missing."
}


$rollbackStart =
    $appText.IndexOf(
        'function Invoke-RithmicRollbackManager')

$rollbackEnd =
    $appText.IndexOf(
        'function Get-RithmicBaselineArchives',
        $rollbackStart)

$rollbackText =
    $appText.Substring(
        $rollbackStart,
        $rollbackEnd - $rollbackStart)

if (-not $rollbackText.Contains('[bool]$plan.TargetExists')) {
    throw "Rollback must authorize verified replacement of a protected existing target."
}

if ($rollbackText -notlike '*existingUndo*' -or
    $rollbackText -notlike '*Using existing undo backup:*') {
    throw "Rollback regression: exact existing undo backups are not reused."
}


$targetNameStart =
    $appText.IndexOf(
        'function Get-RithmicTargetNameFromBackupArchive')

$targetNameEnd =
    $appText.IndexOf(
        'function Get-ScDataSourceNameFromBaselineArchive',
        $targetNameStart)

$targetNameText =
    $appText.Substring(
        $targetNameStart,
        $targetNameEnd - $targetNameStart)

$targetSuffixPatternPosition =
    $targetNameText.IndexOf(
        '$targetSuffixPattern =')

$suffixMatchPosition =
    $targetNameText.IndexOf(
        '$suffixMatch =')

$metadataPosition =
    $targetNameText.IndexOf(
        '$Meta.OriginalName')

if ($targetSuffixPatternPosition -lt 0 -or
    $suffixMatchPosition -lt 0 -or
    $metadataPosition -lt 0 -or
    $targetSuffixPatternPosition -gt
        $suffixMatchPosition -or
    $suffixMatchPosition -gt
        $metadataPosition) {

    throw "Rollback identity regression: composite filename target identity must be parsed before metadata."
}

foreach ($duplicateReviewToken in @(
    'Get-ExactRithmicRollbackBackup',
    'Get-DuplicateRithmicRollbackBackups',
    'Review-RithmicRollbackDuplicates',
    'Clear-ConfirmedRithmicRollbackDuplicates',
    'Remove redundant copies, keeping one verified backup per exact state? [y/N]',
    'Using existing undo backup:'
)) {
    if (-not $appText.Contains($duplicateReviewToken)) {
        throw "Rollback duplicate-review regression: missing $duplicateReviewToken"
    }
}

if ($appText -like '*Remove-DuplicateRithmicRollbackBackups*') {
    throw "Rollback duplicate-review regression: automatic deduplication function returned."
}

$storageCleanupStart =
    $appText.IndexOf(
        'function Invoke-BridgeStorageCleanup')

$storageCleanupEnd =
    $appText.IndexOf(
        'function Finalize-ScidBackupStorage',
        $storageCleanupStart)

$storageCleanupText =
    $appText.Substring(
        $storageCleanupStart,
        $storageCleanupEnd - $storageCleanupStart)

if ($storageCleanupText -like '*Clear-ConfirmedRithmicRollbackDuplicates*') {
    throw "Rollback duplicate-review regression: normal storage cleanup deletes persistent rollback duplicates."
}


$duplicateFunctionStart =
    $appText.IndexOf(
        'function Get-DuplicateRithmicRollbackBackups')

$duplicateFunctionEnd =
    $appText.IndexOf(
        'function Clear-ConfirmedRithmicRollbackDuplicates',
        $duplicateFunctionStart)

$duplicateFunctionText =
    $appText.Substring(
        $duplicateFunctionStart,
        $duplicateFunctionEnd - $duplicateFunctionStart)

if ($duplicateFunctionText -like '*@($duplicateGroups)*') {
    throw "Duplicate-review regression: Generic.List array-subexpression is not Windows PowerShell 5.1 safe."
}

if ($duplicateFunctionText -notlike '*$duplicateGroups.ToArray()*') {
    throw "Duplicate-review regression: duplicate groups are not materialized to an object array."
}

$reviewStart =
    $appText.IndexOf(
        'function Review-RithmicRollbackDuplicates')

$reviewEnd =
    $appText.IndexOf(
        'function Invalidate-BridgeStateForRithmicTarget',
        $reviewStart)

$reviewText =
    $appText.Substring(
        $reviewStart,
        $reviewEnd - $reviewStart)

if ($reviewText -match 'if \(\$Yes\)') {
    throw "Duplicate-review regression: general -Yes must not authorize persistent rollback deletion."
}

$rollbackStart =
    $appText.IndexOf(
        'function Invoke-RithmicRollbackManager')

$rollbackEnd =
    $appText.IndexOf(
        'function Get-RithmicBaselineArchives',
        $rollbackStart)

$rollbackText =
    $appText.Substring(
        $rollbackStart,
        $rollbackEnd - $rollbackStart)

if ($rollbackText -notmatch 'Review-RithmicRollbackDuplicates\s+`\s*\r?\n\s+\$ResolvedDataFolder\s+`\s*\r?\n\s+\$null') {
    throw "Duplicate-review regression: Rollback is not reviewing duplicates across all targets."
}


foreach ($compressionEngineToken in @(
    'FSCTL_SET_COMPRESSION',
    'VolumeSupportsFileCompression',
    'IsFileCompressed',
    'CompressFileVerified',
    'CreateCompressedOutputFile',
    'CompressionSupported',
    'CompressionEnabled',
    'OutputAllocatedBytes'
)) {
    if ($converterText -notlike "*$compressionEngineToken*") {
        throw "Compression regression: engine is missing $compressionEngineToken"
    }
}

foreach ($compressionAppToken in @(
    'Get-RithmicCompressionReport',
    'Review-RithmicTargetCompression',
    'Enable NTFS compression for these Rithmic market-data files? [y/N]',
    'Rithmic compression:'
)) {
    if (-not $appText.Contains($compressionAppToken)) {
        throw "Compression regression: application is missing $compressionAppToken"
    }
}

$updateStart =
    $appText.IndexOf(
        'function Invoke-SierraHistoryBridge')

$updateEnd =
    $appText.IndexOf(
        'function Invoke-SierraHistoryUtilityMode',
        $updateStart)

$updateText =
    $appText.Substring(
        $updateStart,
        $updateEnd - $updateStart)

if ($updateText -like '*CompressFileVerified*') {
    throw "Compression policy regression: normal Update must not recompress existing Rithmic files automatically."
}

$compressionReviewStart =
    $appText.IndexOf(
        'function Review-RithmicTargetCompression')

$compressionReviewEnd =
    $appText.IndexOf(
        'function Select-ArchiveSourceFiles',
        $compressionReviewStart)

$compressionReviewText =
    $appText.Substring(
        $compressionReviewStart,
        $compressionReviewEnd - $compressionReviewStart)

if ($compressionReviewText -notlike '*Read-Host*' -or
    $compressionReviewText -notlike '*Wait-ForSierraChartClosed*') {
    throw "Compression policy regression: existing-file compression must be confirmed and require Sierra Chart closed."
}


foreach ($multiSelectAppToken in @(
    'SelectionFile',
    'Initialize-OperationSelection',
    'Resolve-SelectedOperationItems',
    'Invoke-ExplorerSelectionDispatch',
    'Convert-IndexSelection',
    'Rollback plan: {0} backup(s)',
    'A rollback batch can contain only one backup per target'
)) {
    if ($appText -notlike "*$multiSelectAppToken*") {
        throw "Multi-select regression: application is missing $multiSelectAppToken"
    }
}

foreach ($multiSelectSetupToken in @(
    'MultiSelectModel',
    '"Player"',
    '"Single"',
    '-Mode Explorer',
    '-DispatchMode Archive',
    '-DispatchMode Restore',
    '-DispatchMode Rollback',
    '-WindowStyle Hidden'
)) {
    if ($setupText -notlike "*$multiSelectSetupToken*") {
        throw "Multi-select regression: Explorer integration is missing $multiSelectSetupToken"
    }
}

if ($setupText -like '*-Mode Archive -SelectedFile "%1" -Interactive*' -or
    $setupText -like '*-Mode Restore -SelectedFile "%1" -Interactive*' -or
    $setupText -like '*-Mode Rollback -SelectedFile "%1" -Interactive*') {

    throw "Multi-select regression: Explorer file verbs bypass the selection broker."
}

$archiveManagerStart =
    $appText.IndexOf(
        'function Invoke-SourceArchiveManager')

$archiveManagerEnd =
    $appText.IndexOf(
        'function Get-ArchivedSourceFiles',
        $archiveManagerStart)

$archiveManagerText =
    $appText.Substring(
        $archiveManagerStart,
        $archiveManagerEnd - $archiveManagerStart)

if ($archiveManagerText -notlike '*Resolve-SelectedOperationItems*') {
    throw "Multi-select regression: Archive does not resolve batch selections."
}

$restoreManagerStart =
    $appText.IndexOf(
        'function Invoke-SourceRestoreManager')

$restoreManagerEnd =
    $appText.IndexOf(
        'function Get-RithmicTargetNameFromBackupArchive',
        $restoreManagerStart)

$restoreManagerText =
    $appText.Substring(
        $restoreManagerStart,
        $restoreManagerEnd - $restoreManagerStart)

if ($restoreManagerText -notlike '*Resolve-SelectedOperationItems*') {
    throw "Multi-select regression: Restore does not resolve batch selections."
}

$rollbackManagerStart =
    $appText.IndexOf(
        'function Invoke-RithmicRollbackManager')

$rollbackManagerEnd =
    $appText.IndexOf(
        'function Get-RithmicBaselineArchives',
        $rollbackManagerStart)

$rollbackManagerText =
    $appText.Substring(
        $rollbackManagerStart,
        $rollbackManagerEnd - $rollbackManagerStart)

if ($rollbackManagerText -notlike '*Resolve-SelectedOperationItems*' -or
    $rollbackManagerText -notlike '*Group-Object*TargetName*' -or
    -not $rollbackManagerText.Contains(
        'Roll back {0} target(s) from the selected backup(s)? [y/N]')) {

    throw "Multi-select regression: Rollback batch planning/confirmation is incomplete."
}


$lineEndedBooleanCommandPattern =
    '(?m)-(and|or)\s*\r?\n\s*(?![$(\[])([A-Za-z][A-Za-z0-9_-]*)\b'

$lineEndedBooleanCommandMatch =
    [regex]::Match(
        $appText,
        $lineEndedBooleanCommandPattern)

if ($lineEndedBooleanCommandMatch.Success) {
    throw (
        "PowerShell 5.1 syntax regression: a bare command follows a line-ended boolean operator: " +
        $lineEndedBooleanCommandMatch.Groups[2].Value)
}


foreach ($layoutToken in @(
    'HistoryBridge',
    'HistoryBridgeTemp',
    'storage_folder',
    'sierra_path',
    'StoragePath',
    'TempPath',
    'Logs'
)) {
    if ($appText -notlike "*$layoutToken*" -and
        $setupText -notlike "*$layoutToken*") {

        throw "Layout regression: missing $layoutToken"
    }
}

foreach ($folderToken in @(
    '"Archive"',
    '"Baselines"',
    '"Rollbacks"',
    '"RestoreConflicts"'
)) {
    if ($appText -notlike "*$folderToken*") {
        throw "Layout regression: missing persistent category $folderToken"
    }
}

if ($appText -match '"SCID_Bridge_' -or
    $appText -match '"SC_Data"' -or
    $appText -match '"Rithmic_Baselines"' -or
    $appText -match '"Restore_Conflicts"') {

    throw "Layout regression: previous folder identifiers returned to the application runtime."
}

if ($converterText -notmatch 'Path\.GetFileName\(sourcePath\)\s*\+\s*"--"\s*\+\s*Path\.GetFileName\(targetPath\)') {
    throw "Layout regression: raw baseline separator is not --."
}

foreach ($provenanceToken in @(
    'Normalize-RithmicProvenance',
    'Format-RithmicProvenance',
    'Set-ArchiveProvenance',
    'Get-KnownRithmicProvenanceByHash',
    'Get-StateRithmicProvenance',
    'Resolve-CurrentRithmicProvenance',
    'Resolve-RithmicProvenanceFromContent',
    'Get-RithmicProvenanceCode',
    'Rithmic authentic',
    'Foreign',
    'scid_provenance',
    'daily_provenance'
)) {
    if ($appText -notlike "*$provenanceToken*") {
        throw "Provenance regression: missing $provenanceToken"
    }
}

$pathFunctionStart =
    $appText.IndexOf(
        'function Get-BridgePaths')

$pathFunctionEnd =
    $appText.IndexOf(
        'function Format-LogRecord',
        $pathFunctionStart)

$pathFunctionText =
    $appText.Substring(
        $pathFunctionStart,
        $pathFunctionEnd - $pathFunctionStart)

foreach ($pathToken in @(
    '"HistoryBridge"',
    '"HistoryBridgeTemp"',
    '"Logs"',
    'sierra_path',
    'storage_folder'
)) {
    if ($pathFunctionText -notlike "*$pathToken*") {
        throw "Path-model regression: Get-BridgePaths is missing $pathToken"
    }
}

if ($pathFunctionText -like '*archive_folder*' -or
    $pathFunctionText -like '*recovery_folder*') {

    throw "Path-model regression: runtime still depends on previous archive/recovery config fields."
}

if ($appText -notlike '*%TEMP%*' -and
    $appText -notlike '*$env:TEMP*') {
    throw "Explorer broker regression: transient broker is not rooted in TEMP."
}


if ($converterText -notmatch
    'public\s+bool\s+TryReadRaw\s*\(') {

    throw "C# relationship inspector requires SequentialRecordReader.TryReadRaw."
}

$backupNameStart =
    $appText.IndexOf(
        "function Get-RithmicBackupFileName(",
        [StringComparison]::Ordinal)

$backupNameEnd =
    $appText.IndexOf(
        "function Get-RithmicBackupPrefixFromArchive(",
        $backupNameStart,
        [StringComparison]::Ordinal)

if ($backupNameStart -lt 0 -or
    $backupNameEnd -le $backupNameStart) {

    throw "Provenance filename regression: backup filename function could not be isolated."
}

$backupNameFunctionText =
    $appText.Substring(
        $backupNameStart,
        $backupNameEnd - $backupNameStart)

if ($backupNameFunctionText -match
    'CutoverDateTime|Format-ScDateTimeCompact') {

    throw "Provenance filename regression: backup filenames must contain only the compact identity code, not cutover detail."
}

foreach ($contentEvidenceToken in @(
    'ScidContentInspection',
    'InspectScidContent',
    'InspectGzipScidContent',
    'SCDataLike',
    'ForeignLike',
    'SpecialControlOpenRecords',
    'RegularOpenRecords',
    'content_class',
    'special_control_open_records',
    'regular_open_records'
)) {
    if ($converterText -notlike "*$contentEvidenceToken*") {
        throw "Content-provenance regression: engine is missing $contentEvidenceToken"
    }
}

foreach ($provenanceCodeToken in @(
    'Get-RithmicProvenanceCode',
    'Resolve-RithmicProvenanceFromContent',
    'Get-RithmicBackupFileName',
    '"RT"',
    '"SC"',
    '"MX"',
    '"FR"',
    '"UN"',
    '"Foreign"'
)) {
    if ($appText -notlike "*$provenanceCodeToken*") {
        throw "Provenance-code regression: application is missing $provenanceCodeToken"
    }
}

foreach ($layoutRelocationToken in @(
    'Normalize-RithmicBackupProvenance',
    'Convert-LayoutCompositeBackupName',
    'Rename-SetupBackupForProvenance',
    'InspectGzipScidContent',
    'HistoryBridgeTemp'
)) {
    if ($setupText -notlike "*$layoutRelocationToken*") {
        throw "Layout-relocation regression: Setup is missing $layoutRelocationToken"
    }
}

if ($setupText -notlike '*Sierra History Bridge*') {
    throw "Install-path regression: spaced Windows application name is missing."
}

if ($appText -notlike '*$AppName = "SierraHistoryBridge"*') {
    throw "LocalAppData regression: compact SierraHistoryBridge application identifier is missing."
}


foreach ($identityToken in @(
    'Get-KnownRithmicEvidenceByHash',
    'InspectScidRelationshipToSource',
    'InspectGzipScidRelationshipToSource',
    'scid_sha256',
    'OutputSha256',
    'cutover_datetime'
)) {
    if ($appText -notlike "*$identityToken*" -and
        $converterText -notlike "*$identityToken*") {

        throw "Identity regression: missing $identityToken"
    }
}

foreach ($mergeSafetyToken in @(
    'FindVerifiedHandoffDateTime',
    'HandoffVerifiedTradeSeconds',
    'LIVE_MERGE_HANDOFF_UNVERIFIED',
    'LIVE_MERGE_BOUNDARY_INVALID',
    'CopyScidRangeVerified',
    'ShouldPreserveTargetTail',
    'targetSecond.Volume >',
    'sourceSecond.Volume'
)) {
    if ($converterText -notlike "*$mergeSafetyToken*") {
        throw "Merge-safety regression: engine is missing $mergeSafetyToken"
    }
}

if ($converterText -notmatch
    'ShouldPreserveTargetTail\(' -or
    $converterText -notmatch
    'targetSecond\.Volume\s*>\s*sourceSecond\.Volume') {

    throw "Merge-safety regression: live-tail preservation is not based on whole-second/aggregate endpoint evidence."
}

if ($converterText -notmatch
    'sourcePrefixRecords\s*==\s*0\s*&&\s*exactAfterMismatch\s*==\s*0') {

    throw "Provenance regression: a corrupted SC-like file can be mislabeled Foreign."
}

foreach ($baselineInvariantToken in @(
    'Test-RithmicBaselineAuthenticity',
    'authentic_rithmic_provenance_not_proven',
    'baseline_provenance_not_authenticated'
)) {
    if ($appText -notlike "*$baselineInvariantToken*") {
        throw "Baseline invariant regression: application is missing $baselineInvariantToken"
    }
}

foreach ($setupIdentityToken in @(
    'Normalize-RithmicBackupProvenance',
    'InspectGzipScidRelationshipToSource',
    'Move-SetupBaselineToRollbacks',
    'Move-SetupUnidentifiedBaselineToRollbacks',
    'verified_archive_bytes',
    'verified_archive_write_ticks',
    'HistoryBridgeTemp'
)) {
    if ($setupText -notlike "*$setupIdentityToken*") {
        throw "Setup identity regression: missing $setupIdentityToken"
    }
}

if ($setupText -notmatch
    '(?s)\$filenameCode\s*=.*?"Baselines"\s*\{\s*"UN"') {

    throw "Baseline invariant regression: previous-layout relocation does not mark old Baselines UN before verification."
}

if ($setupText -notmatch
    '(?s)\$provenance\s*=.*?"Baselines"\s*\{\s*"Unknown"') {

    throw "Baseline invariant regression: previous-layout relocation pre-authenticates old Baselines."
}

if ($appText -notlike '*$env:TEMP*' -or
    $appText -notlike '*"SierraHistoryBridge"*' -or
    $appText -notlike '*"Explorer"*') {

    throw "Explorer broker regression: transient selection state is not under TEMP\\SierraHistoryBridge\\Explorer."
}

foreach ($restoreFilenameToken in @(
    'Never fall back to an arbitrary archive stem',
    'Set-SetupArchiveOriginalName',
    '--UN--unidentified.gz'
)) {
    if ($appText -notlike "*$restoreFilenameToken*" -and
        $setupText -notlike "*$restoreFilenameToken*") {

        throw "Restore filename regression: missing $restoreFilenameToken"
    }
}

if ($converterText -notmatch
        'string\s+originalName\s*=\s*Path\.GetFileName\(\s*sourcePath\s*\);' -or
    $converterText -notmatch
        '"original_name="\s*\+\s*Path\.GetFileName\(\s*sourcePath\s*\)') {

    throw "Restore filename regression: archive metadata does not retain the actual source filename."
}

$targetParserStart =
    $appText.IndexOf(
        'function Get-RithmicTargetNameFromBackupArchive')

$targetParserEnd =
    $appText.IndexOf(
        'function Get-ScDataSourceNameFromBaselineArchive',
        $targetParserStart)

$targetParserText =
    $appText.Substring(
        $targetParserStart,
        $targetParserEnd - $targetParserStart)

if ($targetParserText -match 'return \$name\s*\r?\n') {
    # A direct return is permitted only after the strict Rithmic filename check.
    if ($targetParserText -notmatch
        '(?s)\$rithmicPattern\.IsMatch\(\s*\$name\).*?return \$name') {

        throw "Restore filename regression: Rithmic target parser falls back to an arbitrary archive stem."
    }
}

$setupRenameStart =
    $setupText.IndexOf(
        'function Rename-SetupBackupForProvenance')

$setupRenameEnd =
    $setupText.IndexOf(
        'function Normalize-SetupProvenance',
        $setupRenameStart)

$setupRenameText =
    $setupText.Substring(
        $setupRenameStart,
        $setupRenameEnd - $setupRenameStart)

if ($setupRenameText -like '*Format-SetupScDateTimeCompact*') {
    throw "Restore filename regression: hybrid cutover timestamps are encoded in current backup filenames."
}


foreach ($headerOnlyEngineToken in @(
    'header-only SCID files are not preserved',
    'Header-only SCID archives are not restored',
    'GetGzipScidRecordCount',
    'GetGzipRecordCount',
    'header-only Historical Daily files are not preserved',
    'ArchiveGzipVerified'
)) {
    if ($converterText -notlike "*$headerOnlyEngineToken*") {
        throw "Header-only regression: engine is missing $headerOnlyEngineToken"
    }
}

foreach ($headerOnlyAppToken in @(
    'Remove-HeaderOnlyBridgeArchives',
    'Test-MarketDataHasRecords',
    'header-only target; replace without undo',
    'status=REPLACED-WITHOUT-BACKUP',
    'status=NOT-PRESERVED',
    'header-only file(s) ignored'
)) {
    if ($appText -notlike "*$headerOnlyAppToken*") {
        throw "Header-only regression: application is missing $headerOnlyAppToken"
    }
}

if ($appText -like '*ScidBridge]::ArchiveFileGzipVerified(*') {
    throw "Header-only regression: a DLY preservation path still bypasses DailyBridge.ArchiveGzipVerified."
}

$undoStart =
    $appText.IndexOf(
        'function New-RithmicUndoArchive')

$undoEnd =
    $appText.IndexOf(
        'function Convert-IndexSelection',
        $undoStart)

$undoText =
    $appText.Substring(
        $undoStart,
        $undoEnd - $undoStart)

if ($undoText -notlike '*Test-MarketDataHasRecords*') {
    throw "Header-only regression: undo creation does not reject zero-record targets."
}

$restoreStart =
    $appText.IndexOf(
        'function Invoke-SourceRestoreManager')

$restoreEnd =
    $appText.IndexOf(
        'function Get-RithmicTargetNameFromBackupArchive',
        $restoreStart)

$restoreText =
    $appText.Substring(
        $restoreStart,
        $restoreEnd - $restoreStart)

if ($restoreText -notlike '*REPLACED-WITHOUT-BACKUP*') {
    throw "Header-only regression: restore conflict handling can still preserve zero-record destinations."
}


foreach ($headerOnlySetupToken in @(
    'Remove-SetupHeaderOnlyArchives',
    'Remove-SetupHeaderOnlyTempFiles',
    'Header-only archive removed'
)) {
    if ($setupText -notlike "*$headerOnlySetupToken*") {
        throw "Header-only regression: Setup/Repair is missing $headerOnlySetupToken"
    }
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
    "rollback.cmd",
    "storage.cmd",
    "repair.cmd",
    "uninstall.cmd",
    "README.md",
    "README.txt",
    "CHANGELOG.md",
    "CONTRIBUTING.md",
    "SECURITY.md",
    "docs\RELEASE.md",
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
        "run.cmd",
        "archive.cmd",
        "restore.cmd",
        "rollback.cmd",
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
