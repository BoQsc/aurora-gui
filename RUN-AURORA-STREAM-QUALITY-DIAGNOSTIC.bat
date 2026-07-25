@echo off
setlocal
cd /d "%~dp0aurora-stream"
call RUN-QUALITY-DIAGNOSTIC.bat
exit /b %ERRORLEVEL%
