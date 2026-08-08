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

foreach ($requiredPolicyToken in @(
    '$usableHistoryYears = 5',
    '$historyBufferMonths = 3',
    '$forwardBufferMonths = 6',
    'archive-only',
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

$required = @(
    "src\SierraHistoryBridge.ps1",
    "src\ScidBridge.cs",
    "scripts\Setup.ps1",
    "scripts\Build-Release.ps1",
    "setup.cmd",
    "run.cmd",
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

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $RepoRoot "scripts\Setup.ps1"),
    [ref]$tokens,
    [ref]$errors
) | Out-Null

if ($errors.Count -gt 0) {
    throw "Setup.ps1 parse error: $($errors[0].Message)"
}

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $RepoRoot "src\SierraHistoryBridge.ps1"),
    [ref]$tokens,
    [ref]$errors
) | Out-Null

if ($errors.Count -gt 0) {
    throw "SierraHistoryBridge.ps1 parse error: $($errors[0].Message)"
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

