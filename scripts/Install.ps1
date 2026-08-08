# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$Version = "0.0.1"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$SourceDirectory = Join-Path $RepoRoot "src"
$InstallRoot = Join-Path $env:LOCALAPPDATA "SierraHistoryBridge"
$InstallDirectory = Join-Path $InstallRoot "app"

$MainSource = Join-Path $SourceDirectory "SierraHistoryBridge.ps1"
$ConverterSource = Join-Path $SourceDirectory "ScidBridge.cs"

if (-not (Test-Path -LiteralPath $MainSource)) {
    throw "Missing src\SierraHistoryBridge.ps1"
}

if (-not (Test-Path -LiteralPath $ConverterSource)) {
    throw "Missing src\ScidBridge.cs"
}

New-Item -ItemType Directory -Force -Path $InstallDirectory | Out-Null

Copy-Item -LiteralPath $MainSource -Destination (Join-Path $InstallDirectory "SierraHistoryBridge.ps1") -Force
Copy-Item -LiteralPath $ConverterSource -Destination (Join-Path $InstallDirectory "ScidBridge.cs") -Force

$PowerShellExe =
    Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

$InstalledScript = Join-Path $InstallDirectory "SierraHistoryBridge.ps1"

if (-not (Test-Path -LiteralPath $PowerShellExe)) {
    throw "Windows PowerShell could not be found at $PowerShellExe"
}

if (-not (Test-Path -LiteralPath $InstalledScript)) {
    throw "The application files could not be copied to $InstallDirectory"
}

$menuText = "Update Sierra history from SC Data"
$icon = "$env:SystemRoot\System32\shell32.dll,167"

$directoryCommand =
    '"' + $PowerShellExe + '"' +
    ' -NoLogo -NoProfile -ExecutionPolicy Bypass' +
    ' -File "' + $InstalledScript + '"' +
    ' -DataFolder "%1" -Interactive'

$backgroundCommand =
    '"' + $PowerShellExe + '"' +
    ' -NoLogo -NoProfile -ExecutionPolicy Bypass' +
    ' -File "' + $InstalledScript + '"' +
    ' -DataFolder "%V" -Interactive'

$base = [Microsoft.Win32.Registry]::CurrentUser

function Set-MenuCommand(
    [Microsoft.Win32.RegistryKey]$BaseKey,
    [string]$RelativePath,
    [string]$Command) {

    $menuKey = $BaseKey.CreateSubKey($RelativePath)
    try {
        $menuKey.SetValue("", $menuText, [Microsoft.Win32.RegistryValueKind]::String)
        $menuKey.SetValue("Icon", $icon, [Microsoft.Win32.RegistryValueKind]::String)
    }
    finally {
        $menuKey.Dispose()
    }

    $commandKey = $BaseKey.CreateSubKey("$RelativePath\command")
    try {
        $commandKey.SetValue("", $Command, [Microsoft.Win32.RegistryValueKind]::String)
    }
    finally {
        $commandKey.Dispose()
    }
}

try {
    Set-MenuCommand `
        $base `
        "Software\Classes\Directory\shell\SierraHistoryBridge" `
        $directoryCommand

    Set-MenuCommand `
        $base `
        "Software\Classes\Directory\Background\shell\SierraHistoryBridge" `
        $backgroundCommand
}
finally {
    $base.Dispose()
}

Write-Host
Write-Host "Sierra History Bridge v$Version installed."
Write-Host
Write-Host "Explorer command:"
Write-Host "  $menuText"
Write-Host
Write-Host "Installed files:"
Write-Host "  $InstallDirectory"
Write-Host
Write-Host "Right-click a Sierra Chart Data folder, or blank space inside it,"
Write-Host "and choose the Explorer command."
