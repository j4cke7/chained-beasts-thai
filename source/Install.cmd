@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Patch.ps1" -Action Install %*
set "CB_EXIT=%errorlevel%"
if not "%CB_EXIT%"=="0" pause
exit /b %CB_EXIT%
