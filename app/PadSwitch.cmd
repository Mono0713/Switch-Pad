@echo off
rem Prefer PadSwitch.exe: starting powershell from here leaves a Windows Terminal window open on Windows 11
if exist "%~dp0..\PadSwitch.exe" (start "" "%~dp0..\PadSwitch.exe" & exit /b)
start "" powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0nxn-app.ps1"
