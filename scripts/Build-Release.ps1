# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"

function New-PortableZipArchive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDirectory,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [switch]$IncludeRootDirectory
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $source = Get-Item -LiteralPath $SourceDirectory
    if ($IncludeRootDirectory) {
        $basePath = $source.Parent.FullName
    }
    else {
        $basePath = $source.FullName
    }

    $basePath = $basePath + [System.IO.Path]::DirectorySeparatorChar
    $archive = [System.IO.Compression.ZipFile]::Open(
        $DestinationPath,
        [System.IO.Compression.ZipArchiveMode]::Create)

    try {
        if ($IncludeRootDirectory) {
            $directories = @($source) +
                @(Get-ChildItem -LiteralPath $source.FullName -Directory -Recurse)

            foreach ($directory in $directories) {
                $entryName =
                    $directory.FullName.Substring($basePath.Length).Replace('\', '/') +
                    '/'
                [void]$archive.CreateEntry($entryName)
            }
        }

        foreach ($file in (Get-ChildItem `
            -LiteralPath $source.FullName -File -Recurse)) {
            $entryName = $file.FullName.Substring($basePath.Length).Replace('\', '/')
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive,
                $file.FullName,
                $entryName,
                [System.IO.Compression.CompressionLevel]::Optimal)
        }
    }
    finally {
        $archive.Dispose()
    }
}

$Version = "0.0.20"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $RepoRoot "dist"
}

$ReleaseName = "SierraHistoryBridge"
$ReleaseRoot = Join-Path $OutputDirectory $ReleaseName
$ReleaseZip = Join-Path $OutputDirectory "SierraHistoryBridge.zip"

if (Test-Path -LiteralPath $ReleaseRoot) {
    Remove-Item -LiteralPath $ReleaseRoot -Recurse -Force
}
if (Test-Path -LiteralPath $ReleaseZip) {
    Remove-Item -LiteralPath $ReleaseZip -Force
}

New-Item -ItemType Directory -Path $ReleaseRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $ReleaseRoot "app") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $ReleaseRoot "docs") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $ReleaseRoot "setup") -Force | Out-Null

Copy-Item -LiteralPath (Join-Path $RepoRoot "src\SierraHistoryBridge.ps1") `
    -Destination (Join-Path $ReleaseRoot "app\SierraHistoryBridge.ps1")

Copy-Item -LiteralPath (Join-Path $RepoRoot "src\ScidBridge.cs") `
    -Destination (Join-Path $ReleaseRoot "app\ScidBridge.cs")

Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts\Setup.ps1") `
    -Destination (Join-Path $ReleaseRoot "setup\Setup.ps1")

$RepositoryDocs = @(
    "COMMIT-STANDARDS.md",
    "PUBLISHING.md",
    "VERSIONING.md"
)

Get-ChildItem -LiteralPath (Join-Path $RepoRoot "docs") -File |
    Where-Object { $_.Name -notin $RepositoryDocs } |
    Copy-Item -Destination (Join-Path $ReleaseRoot "docs")

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
    "storage.cmd",
    "repair.cmd",
    "uninstall.cmd"
)) {
    Copy-Item -LiteralPath (Join-Path $RepoRoot $name) `
        -Destination (Join-Path $ReleaseRoot $name)
}

# The clean repair payload contains the files that setup can restore. It does
# not contain itself, avoiding recursive archives.
$payloadStage = Join-Path $OutputDirectory "_payload_stage"
if (Test-Path -LiteralPath $payloadStage) {
    Remove-Item -LiteralPath $payloadStage -Recurse -Force
}
New-Item -ItemType Directory -Path $payloadStage -Force | Out-Null

foreach ($directory in @("app", "docs")) {
    Copy-Item -LiteralPath (Join-Path $ReleaseRoot $directory) `
        -Destination (Join-Path $payloadStage $directory) -Recurse
}
New-Item -ItemType Directory -Path (Join-Path $payloadStage "setup") -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $ReleaseRoot "setup\Setup.ps1") `
    -Destination (Join-Path $payloadStage "setup\Setup.ps1")

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
    "storage.cmd",
    "repair.cmd",
    "uninstall.cmd"
)) {
    Copy-Item -LiteralPath (Join-Path $ReleaseRoot $name) `
        -Destination (Join-Path $payloadStage $name)
}

New-PortableZipArchive `
    -SourceDirectory $payloadStage `
    -DestinationPath (Join-Path $ReleaseRoot "setup\payload.zip")

Remove-Item -LiteralPath $payloadStage -Recurse -Force

New-PortableZipArchive `
    -SourceDirectory $ReleaseRoot `
    -DestinationPath $ReleaseZip `
    -IncludeRootDirectory

Write-Host "Built:"
Write-Host "  $ReleaseRoot"
Write-Host "  $ReleaseZip"

