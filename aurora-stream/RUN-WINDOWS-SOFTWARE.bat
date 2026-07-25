@echo off
setlocal
set "AURORA_RENDERER=software"
echo Starting Aurora Stream with the software UI renderer...
call "%~dp0RUN-WINDOWS.bat"
exit /b %errorlevel%
