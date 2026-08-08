@REM SPDX-License-Identifier: MPL-2.0
@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title Uninstall Sierra History Bridge

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass ^
  -File "%~dp0scripts\Uninstall.ps1" %*

set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%
