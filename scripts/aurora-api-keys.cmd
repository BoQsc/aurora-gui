@echo off
rem Convenience wrapper for aurora-api-keys.ps1 (cmd.exe).
rem
rem   scripts\aurora-api-keys.cmd backup -Password "shared secret"
rem   scripts\aurora-api-keys.cmd list    -Path keys.bundle.enc.json -Password "shared secret"
rem   scripts\aurora-api-keys.cmd install -Path keys.bundle.enc.json -Password "shared secret"
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0aurora-api-keys.ps1" %*
exit /b %ERRORLEVEL%
