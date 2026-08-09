# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ConverterSource = Join-Path $RepoRoot "src\ScidBridge.cs"

Add-Type -Path $ConverterSource

$temp = Join-Path ([IO.Path]::GetTempPath()) ("SierraHistoryBridge-Test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temp -Force | Out-Null

function Write-ScidHeader([IO.BinaryWriter]$Writer) {
    $Writer.Write([byte][char]'S')
    $Writer.Write([byte][char]'C')
    $Writer.Write([byte][char]'I')
    $Writer.Write([byte][char]'D')
    $Writer.Write([uint32]56)
    $Writer.Write([uint32]40)
    $Writer.Write([uint16]1)
    $Writer.Write([uint16]0)
    $Writer.Write([uint32]0)
    $Writer.Write((New-Object byte[] 36))
}

function Write-Record(
    [IO.BinaryWriter]$Writer,
    [long]$DateTime,
    [single]$Open,
    [single]$High,
    [single]$Low,
    [single]$Close,
    [uint32]$NumTrades,
    [uint32]$TotalVolume,
    [uint32]$BidVolume,
    [uint32]$AskVolume) {

    $Writer.Write($DateTime)
    $Writer.Write($Open)
    $Writer.Write($High)
    $Writer.Write($Low)
    $Writer.Write($Close)
    $Writer.Write($NumTrades)
    $Writer.Write($TotalVolume)
    $Writer.Write($BidVolume)
    $Writer.Write($AskVolume)
}

try {
    $source = Join-Path $temp "NQU26-CME.scid"
    $target = Join-Path $temp "NQU6.CME.scid"
    $backup = Join-Path $temp "backups"

    $baseTime = [long]4000000000000000

    $stream = [IO.File]::Open($source, [IO.FileMode]::CreateNew)
    $writer = New-Object IO.BinaryWriter($stream)
    try {
        Write-ScidHeader $writer

        for ($i = 0; $i -lt 20; $i++) {
            $open = if ($i -eq 5) { [single]-1.2345e30 } else { [single]0.0 }
            $price = [single](30000.0 + ($i * 0.25))

            $recordTime =
                $baseTime + ($i * 1000000)

            Write-Record `
                $writer `
                $recordTime `
                $open `
                ($price + 0.25) `
                $price `
                $price `
                1 1 1 0
        }
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }

    $headerOnlyScid =
        Join-Path `
            $temp `
            "header-only.scid"

    $stream =
        [IO.File]::Open(
            $headerOnlyScid,
            [IO.FileMode]::CreateNew)

    $writer =
        New-Object IO.BinaryWriter(
            $stream)

    try {
        Write-ScidHeader $writer
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }

    $headerOnlyScidArchive =
        $headerOnlyScid +
        ".gz"

    $headerOnlyRejected =
        $false

    try {
        [SierraHistoryBridge.ScidBridge]::ArchiveScidGzipVerified(
            $headerOnlyScid,
            $headerOnlyScidArchive,
            $false,
            $false) |
            Out-Null
    }
    catch {
        $headerOnlyRejected =
            $_.Exception.Message -like
                "*header-only*not preserved*"
    }

    if (-not $headerOnlyRejected -or
        (Test-Path -LiteralPath $headerOnlyScidArchive)) {

        throw "Header-only SCID preservation guard failed."
    }

    $stream = [IO.File]::Open($target, [IO.FileMode]::CreateNew)
    $writer = New-Object IO.BinaryWriter($stream)
    try {
        Write-ScidHeader $writer

        for ($i = 0; $i -lt 20; $i++) {
            $price = [single](30000.0 + ($i * 0.25))

            Write-Record `
                $writer `
                ($baseTime + ($i * 1000000)) `
                ([single]0.0) `
                ([single](($price + 0.25) * 100.0)) `
                ([single]($price * 100.0)) `
                ([single]($price * 100.0)) `
                1 1 1 0
        }

        # A genuinely newer Rithmic record beyond the source endpoint.
        Write-Record `
            $writer `
            ($baseTime + (23 * 1000000)) `
            ([single]0.0) `
            ([single]3001000.0) `
            ([single]3000975.0) `
            ([single]3001000.0) `
            1 1 0 1
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }

    $sourceInspection =
        [SierraHistoryBridge.ScidBridge]::InspectScidContent(
            $source)

    if ($sourceInspection.ContentClass -ne "SCDataLike" -or
        $sourceInspection.SpecialControlOpenRecords -ne 1 -or
        $sourceInspection.RegularOpenRecords -ne 0) {

        throw "SC Data-like content classification failed."
    }

    $foreignProbe =
        Join-Path `
            $temp `
            "foreign-probe.scid"

    $stream =
        [IO.File]::Open(
            $foreignProbe,
            [IO.FileMode]::CreateNew)

    $writer =
        New-Object IO.BinaryWriter(
            $stream)

    try {
        Write-ScidHeader $writer

        for ($i = 0; $i -lt 4; $i++) {
            Write-Record `
                $writer `
                ($baseTime + ($i * 1000000)) `
                ([single]3000000.0) `
                ([single]3000025.0) `
                ([single]3000000.0) `
                ([single]3000000.0) `
                1 1 1 0
        }
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }

    $foreignInspection =
        [SierraHistoryBridge.ScidBridge]::InspectScidContent(
            $foreignProbe)

    if ($foreignInspection.ContentClass -ne "ForeignLike") {
        throw "Foreign-like content classification failed."
    }

    $mixedProbe =
        Join-Path `
            $temp `
            "mixed-probe.scid"

    [IO.File]::Copy(
        $source,
        $mixedProbe)

    $stream =
        [IO.File]::Open(
            $mixedProbe,
            [IO.FileMode]::Append)

    $writer =
        New-Object IO.BinaryWriter(
            $stream)

    try {
        Write-Record `
            $writer `
            ($baseTime + (30 * 1000000)) `
            ([single]3000000.0) `
            ([single]3000025.0) `
            ([single]3000000.0) `
            ([single]3000000.0) `
            1 1 0 1
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }

    $mixedInspection =
        [SierraHistoryBridge.ScidBridge]::InspectScidContent(
            $mixedProbe)

    if ($mixedInspection.ContentClass -ne "Mixed") {
        throw "Mixed content classification failed."
    }

    Write-Host "PASS: SCID content provenance classification"

    $inference = [SierraHistoryBridge.ScidBridge]::InferScale($source, $target)

    if ([math]::Abs($inference.Factor - 100.0) -gt 0.0001) {
        throw "Expected x100 scale; got x$($inference.Factor)"
    }

    $pairValidation =
        [SierraHistoryBridge.ScidBridge]::ValidatePair(
            $source,
            $target,
            $inference.Factor,
            "[test] validation")

    if ($pairValidation.SourceOutOfOrderRecords -ne 0 -or
        $pairValidation.TargetOutOfOrderRecords -ne 0) {
        throw "Expected monotonic synthetic SCID files."
    }

    if ($pairValidation.CommonSeconds -ne 20) {
        throw "Expected 20 common seconds in SCID pair validation."
    }

    if ($pairValidation.VolumeMatchPercent -ne 100.0 -or
        $pairValidation.LastPriceMatchPercent -ne 100.0) {
        throw "Expected exact synthetic SCID overlap agreement."
    }

    $result = [SierraHistoryBridge.ScidBridge]::Convert(
        $source,
        $target,
        $inference.Factor,
        $backup,
        $false,
        $true,
        "[test] synthetic")

    if ($result.SourceRecords -ne 20) {
        throw "Expected 20 source records."
    }

    if ($result.TailRecords -ne 0) {
        throw "Historical replacement must not preserve a Rithmic tail."
    }

    if ($result.OutputRecords -ne 20) {
        throw "Expected 20 historical replacement records."
    }

    if ($result.OutOfOrderRecords -ne 0) {
        throw "Expected monotonic source timestamps."
    }

    $compressionSupported =
        [SierraHistoryBridge.ScidBridge]::VolumeSupportsFileCompression(
            $temp)

    if ($compressionSupported) {
        if (-not $result.CompressionSupported -or
            -not $result.CompressionEnabled -or
            -not [SierraHistoryBridge.ScidBridge]::IsFileCompressed(
                $target)) {

            throw "Converted SCID did not retain file compression."
        }
    }

    $baselineRaw =
        Join-Path `
            $backup `
            "NQU26-CME.scid--NQU6.CME.scid.rithmic-baseline.bak"

    if (-not (Test-Path -LiteralPath $baselineRaw)) {
        throw "Expected immutable Rithmic baseline backup was not created."
    }

    $baselineArchive =
        Join-Path `
            $temp `
            "NQU6.CME.scid.gz"

    $archiveResult =
        [SierraHistoryBridge.ScidBridge]::ArchiveScidGzipVerified(
            $baselineRaw,
            $baselineArchive,
            $true,
            $false)

    if ([string]::IsNullOrWhiteSpace(
            $archiveResult.ContentClass)) {

        throw "SCID archive did not return content evidence."
    }

    $gzipInspection =
        [SierraHistoryBridge.ScidBridge]::InspectGzipScidContent(
            $baselineArchive)

    if ($gzipInspection.Sha256 -ine
            $archiveResult.Sha256 -or
        $gzipInspection.Length -ne
            $archiveResult.OriginalBytes -or
        $gzipInspection.ContentClass -ne
            $archiveResult.ContentClass) {

        throw "GZip SCID content inspection did not match archive creation evidence."
    }

    if (Test-Path -LiteralPath $baselineRaw) {
        throw "Compressed baseline should remove the raw baseline after verification."
    }

    if (-not (Test-Path -LiteralPath $baselineArchive) -or
        -not (Test-Path -LiteralPath ($baselineArchive + ".meta"))) {
        throw "Compressed baseline archive or metadata is missing."
    }

    $archivedPair =
        [SierraHistoryBridge.ScidBridge]::ValidatePairGzipTarget(
            $source,
            $baselineArchive,
            $pairValidation.TargetLength,
            $pairValidation.TargetFirstDateTime,
            $pairValidation.TargetLastDateTime,
            $inference.Factor,
            "[test] archived validation")

    if ($archivedPair.CommonSeconds -ne 20 -or
        $archivedPair.VolumeMatchPercent -ne 100.0 -or
        $archivedPair.LastPriceMatchPercent -ne 100.0) {
        throw "Compressed Rithmic baseline validation failed."
    }

    Write-Host "PASS: compressed Rithmic baseline round-trip and validation"

    # Live merge provenance coverage uses source/target timestamps that differ
    # inside the same second and both files end in that same second. The SC
    # source is partial while the Rithmic target has greater final-second trade
    # volume, so a clean handoff must move backward to three independently
    # matching trade seconds.
    $mergeSource =
        Join-Path `
            $temp `
            "merge-source.scid"

    $mergeTarget =
        Join-Path `
            $temp `
            "merge-target.scid"

    $mergeBackup =
        Join-Path `
            $temp `
            "merge-backups"

    $mergeBase =
        [long]4010000000000000

    $stream =
        [IO.File]::Open(
            $mergeSource,
            [IO.FileMode]::CreateNew)

    $writer =
        New-Object IO.BinaryWriter(
            $stream)

    try {
        Write-ScidHeader $writer

        for ($second = 0; $second -le 4; $second++) {
            $price =
                [single](31000.0 + ($second * 0.25))

            Write-Record `
                $writer `
                ($mergeBase + ($second * 1000000) + 123000) `
                ([single]0.0) `
                ($price + 0.25) `
                $price `
                $price `
                1 1 1 0
        }

        # Only the first trade from second 5 is present in the SC source.
        Write-Record `
            $writer `
            ($mergeBase + (5 * 1000000) + 123000) `
            ([single]0.0) `
            ([single]31002.0) `
            ([single]31001.25) `
            ([single]31001.25) `
            1 1 1 0
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }

    $stream =
        [IO.File]::Open(
            $mergeTarget,
            [IO.FileMode]::CreateNew)

    $writer =
        New-Object IO.BinaryWriter(
            $stream)

    try {
        Write-ScidHeader $writer

        for ($second = 0; $second -le 4; $second++) {
            $price =
                [single](31000.0 + ($second * 0.25))

            Write-Record `
                $writer `
                ($mergeBase + ($second * 1000000)) `
                ([single]($price * 100.0)) `
                ([single](($price + 0.25) * 100.0)) `
                ([single]($price * 100.0)) `
                ([single]($price * 100.0)) `
                1 1 1 0
        }

        # Full second 5 contains three Rithmic records, so it must not be
        # accepted as matching the partial SC second.
        for ($trade = 0; $trade -lt 3; $trade++) {
            $price =
                [single](31001.25 + ($trade * 0.25))

            Write-Record `
                $writer `
                ($mergeBase + (5 * 1000000) + $trade) `
                ([single]($price * 100.0)) `
                ([single](($price + 0.25) * 100.0)) `
                ([single]($price * 100.0)) `
                ([single]($price * 100.0)) `
                1 1 `
                ([uint32]$(if ($trade -eq 2) { 0 } else { 1 })) `
                ([uint32]$(if ($trade -eq 2) { 1 } else { 0 }))
        }

    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }

    $mergeResult =
        [SierraHistoryBridge.ScidBridge]::Convert(
            $mergeSource,
            $mergeTarget,
            100.0,
            $mergeBackup,
            $true,
            $false,
            "[test] live merge")

    $expectedHandoff =
        $mergeBase +
        (4 * 1000000)

    if ($mergeResult.HandoffDateTime -ne
            $expectedHandoff -or
        $mergeResult.HandoffVerifiedTradeSeconds -lt 3) {

        throw (
            "Verified whole-second handoff failed. Expected " +
            $expectedHandoff +
            "; got " +
            $mergeResult.HandoffDateTime)
    }

    if ($mergeResult.SourceRecordsWritten -ne 4) {
        throw "Live merge source prefix was not strictly before the handoff second."
    }

    if ($mergeResult.TailRecords -ne 4 -or
        $mergeResult.OutputRecords -ne 8) {

        throw "Live merge produced an unexpected prefix/tail record count."
    }

    $finalMergeHash =
        [SierraHistoryBridge.ScidBridge]::HashFileSha256(
            $mergeTarget)

    if ([string]::IsNullOrWhiteSpace(
            $mergeResult.OutputSha256) -or
        $mergeResult.OutputSha256 -ine
            $finalMergeHash) {

        throw "Conversion output SHA-256 does not authenticate the published target."
    }

    $mergeRelationship =
        [SierraHistoryBridge.ScidBridge]::InspectScidRelationshipToSource(
            $mergeSource,
            $mergeTarget,
            100.0)

    if ($mergeRelationship.Relationship -ne "Mixed" -or
        -not $mergeRelationship.WholeSecondCutover -or
        $mergeRelationship.CutoverDateTime -ne
            $expectedHandoff -or
        $mergeRelationship.ExactRecordsAfterMismatch -ne 0) {

        throw "Published live merge does not have a clean SC Data/Rithmic cutover."
    }

    $mergeArchive =
        Join-Path `
            $temp `
            "merge--MX--merge-target.scid.gz"

    $mergeArchiveResult =
        [SierraHistoryBridge.ScidBridge]::ArchiveScidGzipVerified(
            $mergeTarget,
            $mergeArchive,
            $false,
            $false)

    $archivedRelationship =
        [SierraHistoryBridge.ScidBridge]::InspectGzipScidRelationshipToSource(
            $mergeSource,
            $mergeArchive,
            $mergeArchiveResult.OriginalBytes,
            100.0)

    if ($archivedRelationship.Relationship -ne "Mixed" -or
        $archivedRelationship.CutoverDateTime -ne
            $expectedHandoff) {

        throw "Compressed rollback relationship did not preserve the exact mixed cutoff."
    }

    Write-Host "PASS: whole-second half-open live merge and provenance cutoff"

    $genericDaily =
        Join-Path $temp "NQU6.CME.dly.bak"

    [IO.File]::WriteAllText(
        $genericDaily,
        "Date, Open, High, Low, Close, Volume, OpenInterest`r`n2026/08/07, 1, 2, 0, 1, 10, 0`r`n")

    $genericDailyArchive =
        Join-Path $temp "NQU6.CME.dly.gz"

    [void][SierraHistoryBridge.ScidBridge]::ArchiveFileGzipVerified(
        $genericDaily,
        $genericDailyArchive,
        $true,
        $false)

    if ((Test-Path -LiteralPath $genericDaily) -or
        -not (Test-Path -LiteralPath $genericDailyArchive)) {
        throw "Generic compressed backup archive failed."
    }

    Write-Host "PASS: generic compressed file archive"

    $meta = [SierraHistoryBridge.ScidBridge]::GetMeta($target)
    if ($meta.Records -ne 20) {
        throw "Converted historical target metadata is incorrect."
    }

    # Verify the special Open marker is bit-for-bit unchanged.
    $sourceBytes = [IO.File]::ReadAllBytes($source)
    $targetBytes = [IO.File]::ReadAllBytes($target)
    $recordOffset = 56 + (5 * 40) + 8

    for ($i = 0; $i -lt 4; $i++) {
        if ($sourceBytes[$recordOffset + $i] -ne $targetBytes[$recordOffset + $i]) {
            throw "Special Open marker was changed."
        }
    }

    $restoredBaselineTarget =
        Join-Path $temp "NQU6-restored.CME.scid"

    $baselineMetaLines =
        Get-Content -LiteralPath ($baselineArchive + ".meta")

    $baselineMeta = @{}
    foreach ($line in $baselineMetaLines) {
        $separator = $line.IndexOf("=")
        if ($separator -gt 0) {
            $baselineMeta[$line.Substring(0, $separator)] =
                $line.Substring($separator + 1)
        }
    }

    $restoreResult =
        [SierraHistoryBridge.ScidBridge]::RestoreFileGzipVerified(
            $baselineArchive,
            $restoredBaselineTarget,
            [long]$baselineMeta["original_bytes"],
            [string]$baselineMeta["sha256"],
            [long]$baselineMeta["original_write_ticks"],
            $true,
            $false)

    if (-not (Test-Path -LiteralPath $restoredBaselineTarget)) {
        throw "Compressed SCID restore round-trip failed."
    }

    if ($compressionSupported) {
        if (-not $restoreResult.CompressionSupported -or
            -not $restoreResult.CompressionEnabled -or
            -not [SierraHistoryBridge.ScidBridge]::IsFileCompressed(
                $restoredBaselineTarget)) {

            throw "Restored SCID did not retain file compression."
        }
    }

    Write-Host "PASS: compressed SCID restore round-trip"

    # Rollback replacement path: a verified archive must be able to atomically
    # replace an existing destination when replacement has been explicitly
    # authorized.
    $replaceTarget =
        Join-Path `
            $temp `
            "NQU6-replace.CME.scid"

    [IO.File]::WriteAllBytes(
        $replaceTarget,
        [byte[]](1, 2, 3, 4))

    [void][SierraHistoryBridge.ScidBridge]::RestoreFileGzipVerified(
        $baselineArchive,
        $replaceTarget,
        [long]$baselineMeta["original_bytes"],
        [string]$baselineMeta["sha256"],
        [long]$baselineMeta["original_write_ticks"],
        $true,
        $true)

    $replaceHash =
        [SierraHistoryBridge.ScidBridge]::HashFileSha256(
            $replaceTarget)

    if ($replaceHash -ne
        [string]$baselineMeta["sha256"]) {

        throw "Authorized archive replacement failed."
    }

    Write-Host "PASS: verified archive replacement"

    $mergeMeta =
        [SierraHistoryBridge.ScidBridge]::GetMeta($mergeTarget)

    if ($mergeMeta.Records -ne 8 -or
        $mergeMeta.LastDateTime -ne
            ($mergeBase + (5 * 1000000) + 2)) {
        throw "Published live merge metadata is incorrect."
    }

    $unorderedSource = Join-Path $temp "unordered-source.scid"
    $unorderedTarget = Join-Path $temp "unordered-target.scid"
    Copy-Item -LiteralPath $source -Destination $unorderedSource
    Copy-Item -LiteralPath $target -Destination $unorderedTarget

    $stream = [IO.File]::Open(
        $unorderedSource,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None)
    $writer = New-Object IO.BinaryWriter($stream)
    try {
        $stream.Position = 56 + (10 * 40)
        $writer.Write($baseTime + (8 * 1000000))
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }

    $unorderedTargetBefore =
        [Convert]::ToBase64String(
            [IO.File]::ReadAllBytes($unorderedTarget))

    $unorderedRejected = $false
    try {
        [SierraHistoryBridge.ScidBridge]::Convert(
            $unorderedSource,
            $unorderedTarget,
            100.0,
            $mergeBackup,
            $false,
            $false,
            "[test] unordered source") | Out-Null
    }
    catch {
        $unorderedRejected =
            $_.Exception.Message -like "*SOURCE_OUT_OF_ORDER:*"
    }

    if (-not $unorderedRejected) {
        throw "Non-monotonic SC Data source was not rejected."
    }

    $unorderedTargetAfter =
        [Convert]::ToBase64String(
            [IO.File]::ReadAllBytes($unorderedTarget))

    if ($unorderedTargetAfter -ne $unorderedTargetBefore) {
        throw "Rejected non-monotonic source changed its target."
    }


    $dailySource = Join-Path $temp "NQU26-CME.dly"
    $dailyTarget = Join-Path $temp "NQU6.CME.dly"

    @(
        "Date, Open, High, Low, Close, Volume, OpenInterest",
        "2026/01/01, 100.00, 101.00, 99.00, 100.50, 1000, 10",
        "2026/01/02, 101.00, 102.00, 100.00, 101.50, 1100, 11",
        "2026/01/03, 102.00, 103.00, 101.00, 102.50, 1200, 0"
    ) | Set-Content -LiteralPath $dailySource -Encoding ASCII

    @(
        "Date, Open, High, Low, Close, Volume, OpenInterest",
        "2025/12/31, 9900.00000000, 9950.00000000, 9850.00000000, 9925.00000000, 900, 9",
        "2026/01/03, 10225.00000000, 10325.00000000, 10125.00000000, 10300.00000000, 1300, 12",
        "2026/01/04, 10300.00000000, 10400.00000000, 10200.00000000, 10350.00000000, 1400, 13"
    ) | Set-Content -LiteralPath $dailyTarget -Encoding ASCII

    $headerOnlyDaily =
        Join-Path `
            $temp `
            "header-only.dly"

    @(
        "Date, Open, High, Low, Close, Volume, OpenInterest"
    ) |
        Set-Content `
            -LiteralPath $headerOnlyDaily `
            -Encoding ASCII

    $headerOnlyDailyArchive =
        $headerOnlyDaily +
        ".gz"

    $headerOnlyDailyRejected =
        $false

    try {
        [SierraHistoryBridge.DailyBridge]::ArchiveGzipVerified(
            $headerOnlyDaily,
            $headerOnlyDailyArchive,
            $false,
            $false) |
            Out-Null
    }
    catch {
        $headerOnlyDailyRejected =
            $_.Exception.Message -like
                "*header-only*not preserved*"
    }

    if (-not $headerOnlyDailyRejected -or
        (Test-Path -LiteralPath $headerOnlyDailyArchive)) {

        throw "Header-only Historical Daily preservation guard failed."
    }

    $zeroVolumeDaily =
        Join-Path $temp "NQU00-CME.dly"

    @(
        "Date, Open, High, Low, Close, Volume, OpenInterest",
        "2000/06/01, 100.00, 101.00, 99.00, 100.50, 0, 0",
        "2000/06/02, 101.00, 102.00, 100.00, 101.50, 10, 0"
    ) | Set-Content -LiteralPath $zeroVolumeDaily -Encoding ASCII

    $zeroDailyMeta =
        [SierraHistoryBridge.DailyBridge]::GetMeta(
            $zeroVolumeDaily)

    if ($zeroDailyMeta.ZeroVolumeRecords -ne 1 -or
        $zeroDailyMeta.PositiveVolumeRecords -ne 1) {
        throw "Historical Daily zero-volume metadata accounting failed."
    }

    Write-Host "PASS: Historical Daily zero-volume quality accounting"


    $dailyScaleSource =
        Join-Path $temp "NQH26-CME.dly"

    $dailyScaleTarget =
        Join-Path $temp "NQH6.CME.dly"

    @(
        "Date, Open, High, Low, Close, Volume, OpenInterest",
        "2026/02/01, 100.00, 101.00, 99.00, 100.50, 1000, 10",
        "2026/02/02, 101.00, 102.00, 100.00, 101.50, 1100, 11",
        "2026/02/03, 102.00, 103.00, 101.00, 102.50, 1200, 12",
        "2026/02/04, 103.00, 104.00, 102.00, 103.50, 1300, 13",
        "2026/02/05, 104.00, 105.00, 103.00, 104.50, 1400, 14"
    ) | Set-Content -LiteralPath $dailyScaleSource -Encoding ASCII

    @(
        "Date, Open, High, Low, Close, Volume, OpenInterest",
        "2026/02/01, 10000.00000000, 10100.00000000, 9900.00000000, 10050.00000000, 1000, 10",
        "2026/02/02, 10100.00000000, 10200.00000000, 10000.00000000, 10150.00000000, 1100, 11",
        "2026/02/03, 10200.00000000, 10300.00000000, 10100.00000000, 10250.00000000, 1200, 12",
        "2026/02/04, 10300.00000000, 10400.00000000, 10200.00000000, 10350.00000000, 1300, 13",
        "2026/02/05, 10400.00000000, 10500.00000000, 10300.00000000, 10450.00000000, 1400, 14"
    ) | Set-Content -LiteralPath $dailyScaleTarget -Encoding ASCII

    $dailyScale =
        [SierraHistoryBridge.DailyBridge]::InferScale(
            $dailyScaleSource,
            $dailyScaleTarget)

    if ($dailyScale.Factor -ne 100.0) {
        throw "Expected Historical Daily scale inference of x100."
    }

    if ([SierraHistoryBridge.DailyBridge]::IsSynchronized(
            $dailySource,
            $dailyTarget,
            100.0)) {
        throw "Historical Daily target should require synchronization before the merge."
    }

    $dailyResult =
        [SierraHistoryBridge.DailyBridge]::Sync(
            $dailySource,
            $dailyTarget,
            100.0,
            $backup)

    if (-not [SierraHistoryBridge.DailyBridge]::IsSynchronized(
            $dailySource,
            $dailyTarget,
            100.0)) {
        throw "Historical Daily target should be synchronized after the merge."
    }

    if ($dailyResult.SourceRecords -ne 3) {
        throw "Expected 3 Historical Daily source records."
    }

    if ($dailyResult.SourceAppliedRecords -ne 2) {
        throw "Expected 2 Historical Daily source records to be applied."
    }

    if ($dailyResult.PreservedTargetRecords -ne 2) {
        throw "Expected 2 Historical Daily target records to be retained."
    }

    if ($dailyResult.ReplacedOrDroppedTargetRecords -ne 1) {
        throw "Expected 1 older target-only Historical Daily record to be dropped."
    }

    if ($dailyResult.OutputRecords -ne 4) {
        throw "Expected 4 Historical Daily output records."
    }

    if (-not $dailyResult.PreservedLatestSourceDate) {
        throw "Expected the overlapping latest source date to remain from the Rithmic target."
    }

    if ($compressionSupported) {
        if (-not $dailyResult.CompressionSupported -or
            -not $dailyResult.CompressionEnabled -or
            -not [SierraHistoryBridge.ScidBridge]::IsFileCompressed(
                $dailyTarget)) {

            throw "Historical Daily target did not retain file compression."
        }
    }

    $dailyText = Get-Content -LiteralPath $dailyTarget -Raw

    if ($dailyText -notmatch
        '2026/01/01,\s+10000\.00000000,\s+10100\.00000000') {
        throw "Historical Daily source prices were not scaled."
    }

    if ($dailyText -notmatch
        '2026/01/03,\s+10225\.00000000,\s+10325\.00000000') {
        throw "Historical Daily latest-date target record was not retained."
    }

    if (-not (Test-Path -LiteralPath (Join-Path $backup "NQU6.CME.dly.bak"))) {
        throw "Expected Historical Daily backup file was not created."
    }


    $historicalMeta =
        [SierraHistoryBridge.ScidBridge]::GetMeta(
            $target)

    if ($historicalMeta.Length -ne
        ([SierraHistoryBridge.ScidBridge]::GetMeta($source)).Length) {
        throw "Historical replacement must have the same byte length as the source."
    }

    if ($compressionSupported) {
        $compressionProbe =
            Join-Path `
                $temp `
                "compression-probe.bin"

        [IO.File]::WriteAllBytes(
            $compressionProbe,
            (New-Object byte[] (4 * 1024 * 1024)))

        $compressionResult =
            [SierraHistoryBridge.ScidBridge]::CompressFileVerified(
                $compressionProbe)

        if (-not $compressionResult.Supported -or
            -not $compressionResult.IsCompressed -or
            -not [SierraHistoryBridge.ScidBridge]::IsFileCompressed(
                $compressionProbe)) {

            throw "Verified existing-file compression failed."
        }

        Write-Host "PASS: Windows file compression"
    }
    else {
        Write-Host "SKIP: Windows file compression is not supported on the test volume."
    }

    Write-Host "PASS: scale inference"
    Write-Host "PASS: SCID pair preflight validation"
    Write-Host "PASS: historical SCID replacement"
    Write-Host "PASS: verified whole-second Rithmic tail handoff"
    Write-Host "PASS: non-monotonic source rejection without publication"
    Write-Host "PASS: immutable Rithmic baseline creation"
    Write-Host "PASS: Sierra Open-field marker preservation"
    Write-Host "PASS: header-only SCID preservation rejection"
    Write-Host "PASS: header-only Historical Daily preservation rejection"
    Write-Host "PASS: Historical Daily independent scale inference"
    Write-Host "PASS: Historical Daily merge and scale conversion"
    Write-Host "PASS: Historical Daily older target-only rows are not carried forward"
    Write-Host "PASS: Historical Daily latest-date overlap handling"
    Write-Host "PASS: Historical Daily semantic dirty-check"
    exit 0
}
finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
