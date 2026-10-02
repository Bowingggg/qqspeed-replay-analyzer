@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Data\App\ProjectBootstrap.ps1"
if errorlevel 1 (
  echo.
  echo Frontend stopped with an error.
  pause
)
