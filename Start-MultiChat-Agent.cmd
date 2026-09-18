@echo off
setlocal
start "" powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0MultiChat-Tray.ps1"
exit /b 0
