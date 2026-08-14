@echo off
setlocal
pushd "%~dp0" >nul

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\make-release.ps1" %*
set "code=%errorlevel%"

popd >nul
exit /b %code%
