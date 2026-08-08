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
                if ($i -eq 10) {
                    $baseTime + (8 * 1000000)
                }
                else {
                    $baseTime + ($i * 1000000)
                }

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

        # A genuinely newer Rithmic record beyond the two-second guard.
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

    $inference = [SierraHistoryBridge.ScidBridge]::InferScale($source, $target)

    if ([math]::Abs($inference.Factor - 100.0) -gt 0.0001) {
        throw "Expected x100 scale; got x$($inference.Factor)"
    }

    $result = [SierraHistoryBridge.ScidBridge]::Convert(
        $source,
        $target,
        $inference.Factor,
        $backup,
        2.0)

    if ($result.SourceRecords -ne 20) {
        throw "Expected 20 source records."
    }

    if ($result.TailRecords -ne 1) {
        throw "Expected one preserved Rithmic tail record."
    }

    if ($result.OutputRecords -ne 21) {
        throw "Expected 21 output records."
    }

    if ($result.OutOfOrderRecords -ne 1) {
        throw "Expected one preserved out-of-order source timestamp."
    }

    if ($result.FirstOutOfOrderIndex -ne 10) {
        throw "Unexpected first out-of-order source record index."
    }

    if (-not (Test-Path -LiteralPath (Join-Path $backup "NQU6.CME.scid.bak"))) {
        throw "Expected backup file was not created."
    }

    $meta = [SierraHistoryBridge.ScidBridge]::GetMeta($target)
    if ($meta.Records -ne 21) {
        throw "Converted target metadata is incorrect."
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

    Write-Host "PASS: scale inference"
    Write-Host "PASS: SCID conversion"
    Write-Host "PASS: newer Rithmic tail preservation"
    Write-Host "PASS: backup creation"
    Write-Host "PASS: Sierra Open-field marker preservation"
    Write-Host "PASS: out-of-order source timestamp preserved and reported"
    exit 0
}
finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

