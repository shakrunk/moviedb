@echo off
REM ════════════════════════════════════════════════════════════════════════
REM  THE PROJECTION ROOM — one-click launcher
REM  Double-click this file to start the local server and open the app in
REM  your default browser. Close this window (or click "Close" in the app)
REM  to stop the server.
REM ════════════════════════════════════════════════════════════════════════
title The Projection Room
cd /d "%~dp0"

where pwsh >nul 2>nul
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "MovieTrackerWeb.ps1"
) else (
    echo.
    echo   PowerShell 7 ^(pwsh^) was not found on this PC.
    echo   Install it from https://aka.ms/powershell then double-click this file again.
    echo.
    pause
)
