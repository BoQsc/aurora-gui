@echo off
rem Close any running Aurora ISO (elevated copies need the UAC prompt) and rebuild.
setlocal
pushd "%~dp0" >nul

taskkill /IM aurora-iso.exe /F >nul 2>nul

if exist "%~dp0aurora-iso.exe" (
    echo Closing the running Aurora ISO ^(approve the UAC prompt if shown^)...
    powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath taskkill.exe -ArgumentList '/IM','aurora-iso.exe','/F' -Wait" >nul 2>nul
    timeout /t 1 >nul
)

where dub >nul 2>nul
if errorlevel 1 (
    echo ERROR: DUB was not found on PATH.
    popd >nul
    exit /b 1
)

echo Building Aurora ISO ^(release^)...
dub build --build=portable-single-exe --force
set "code=%errorlevel%"
popd >nul
exit /b %code%
