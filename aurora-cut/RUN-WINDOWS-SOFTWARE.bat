@echo off
echo Aurora Cut 0.60.0
setlocal
set "AURORA_RENDERER=software"
echo Starting Aurora Cut with the software renderer...
call "%~dp0RUN-WINDOWS.bat"
exit /b %errorlevel%
