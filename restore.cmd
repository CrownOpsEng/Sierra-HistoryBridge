@REM SPDX-License-Identifier: MPL-2.0
@echo off
call "%~dp0run.cmd" -Mode Restore %*
exit /b %ERRORLEVEL%
