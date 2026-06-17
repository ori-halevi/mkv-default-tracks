@echo off
chcp 65001 > nul
REM Launcher for Set-MkvDefaults.ps1
REM Usage:
REM   1) Double-click - then enter or drag a folder (or a single video file) into the window.
REM   2) Drag a folder OR a single video file ONTO this .bat - it runs on that target directly.
REM Handles .mkv, .mp4, .mov and more (see the script header for the full list).

if "%~1"=="" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-MkvDefaults.ps1"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-MkvDefaults.ps1" -Folder "%~1"
)
