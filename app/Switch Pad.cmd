@echo off
rem Prefer Switch Pad.exe: starting powershell from here leaves a Windows Terminal window open on Windows 11
if exist "%~dp0..\Switch Pad.exe" (start "" "%~dp0..\Switch Pad.exe" & exit /b)
start "" powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0nxn-app.ps1"
