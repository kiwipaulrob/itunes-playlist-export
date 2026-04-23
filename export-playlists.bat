@echo off
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0export-playlists.ps1"
if %ERRORLEVEL% equ 9009 (
    echo.
    echo ERROR: PowerShell 7 (pwsh.exe) not found.
    echo Download from: https://aka.ms/powershell
    pause
    exit /b 1
)
if %ERRORLEVEL% neq 0 (
    echo.
    echo Script exited with error code %ERRORLEVEL%
    pause
)
