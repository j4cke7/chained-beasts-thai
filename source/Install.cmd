@echo off
set "THAI_MOD_PICK=1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Patch.ps1" -Action Install %*
set "CB_EXIT=%errorlevel%"
pause
exit /b %CB_EXIT%
