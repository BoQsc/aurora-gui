@echo off
REM Forward to aurora-cut subfolder (aurora-cut was moved from repo root)
call "%~dp0aurora-cut\RUN-WINDOWS.bat" %*
exit /b %errorlevel%
