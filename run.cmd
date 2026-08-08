@REM SPDX-License-Identifier: MPL-2.0
@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title Sierra History Bridge

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass ^
  -File "%~dp0src\SierraHistoryBridge.ps1" -Interactive %*

exit /b %ERRORLEVEL%
