@REM SPDX-License-Identifier: MPL-2.0
@echo off
setlocal EnableExtensions
set "PWSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "SETUP="

if exist "%~dp0setup\Setup.ps1" set "SETUP=%~dp0setup\Setup.ps1"
if not defined SETUP if exist "%~dp0scripts\Setup.ps1" set "SETUP=%~dp0scripts\Setup.ps1"

if not defined SETUP (
    echo Setup.ps1 could not be found.
    echo.
    pause
    exit /b 1
)

rem Do not keep the installation directory as cmd.exe's working directory
rem while the uninstaller schedules the application folder for deletion.
cd /d "%TEMP%"
title Uninstall Sierra History Bridge

"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SETUP%" -Mode Uninstall -Interactive
exit /b %ERRORLEVEL%

