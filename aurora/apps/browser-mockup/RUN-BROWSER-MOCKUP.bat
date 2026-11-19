@echo off
setlocal
cd /d "%~dp0"

where python >nul 2>nul
if errorlevel 1 (
    echo Python 3 is required on PATH to launch the Aurora live host.
    pause
    exit /b 1
)

python -B run.py
if errorlevel 1 (
    echo.
    echo Launch failed. See build\browser-mockup\hotswap.log.
    pause
)
endlocal
