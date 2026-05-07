@echo off
chcp 65001 > nul
REM Launcher for Set-MkvDefaults.ps1
REM Usage:
REM   1) Double-click - then enter or drag the folder into the window.
REM   2) Drag a folder ONTO this .bat file - it runs on that folder directly.

if "%~1"=="" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-MkvDefaults.ps1"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-MkvDefaults.ps1" -Folder "%~1"
)
