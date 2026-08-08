@REM SPDX-License-Identifier: MPL-2.0
@echo off
setlocal EnableExtensions
set "PWSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
cd /d "%~dp0"
title Sierra History Bridge Setup

if exist "%~dp0setup\Setup.ps1" (
    set "SETUP=%~dp0setup\Setup.ps1"
) else if exist "%~dp0scripts\Setup.ps1" (
    set "SETUP=%~dp0scripts\Setup.ps1"
) else (
    echo Setup.ps1 could not be found.
    echo.
    pause
    exit /b 1
)

"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SETUP%" -Mode Install -Interactive
exit /b %ERRORLEVEL%
