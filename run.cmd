@REM SPDX-License-Identifier: MPL-2.0
@echo off
setlocal EnableExtensions
set "PWSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
cd /d "%~dp0"
title Sierra History Bridge

if exist "%~dp0app\SierraHistoryBridge.ps1" (
    set "APP=%~dp0app\SierraHistoryBridge.ps1"
) else if exist "%~dp0src\SierraHistoryBridge.ps1" (
    set "APP=%~dp0src\SierraHistoryBridge.ps1"
) else (
    echo SierraHistoryBridge.ps1 could not be found.
    echo.
    pause
    exit /b 1
)

"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%APP%" -Interactive %*
exit /b %ERRORLEVEL%

