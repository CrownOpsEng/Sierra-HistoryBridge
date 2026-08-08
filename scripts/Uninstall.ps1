# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [switch]$RemoveSettings
)

$ErrorActionPreference = "Stop"

$InstallRoot = Join-Path $env:LOCALAPPDATA "SierraHistoryBridge"
$InstallDirectory = Join-Path $InstallRoot "app"

$base = [Microsoft.Win32.Registry]::CurrentUser

try {
    foreach ($relativePath in @(
        "Software\Classes\Directory\shell\SierraHistoryBridge",
        "Software\Classes\Directory\Background\shell\SierraHistoryBridge"
    )) {
        try {
            $base.DeleteSubKeyTree($relativePath, $false)
        }
        catch { }
    }
}
finally {
    $base.Dispose()
}

if (Test-Path -LiteralPath $InstallDirectory) {
    Remove-Item -LiteralPath $InstallDirectory -Recurse -Force
}

if ($RemoveSettings -and (Test-Path -LiteralPath $InstallRoot)) {
    Remove-Item -LiteralPath $InstallRoot -Recurse -Force
}

Write-Host
Write-Host "Sierra History Bridge Explorer integration removed."

if (-not $RemoveSettings) {
    Write-Host "Saved folder, scale, and processed-file state was retained at:"
    Write-Host "  $InstallRoot"
}
