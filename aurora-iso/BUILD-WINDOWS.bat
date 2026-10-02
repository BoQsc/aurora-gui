@echo off
setlocal
set "repo=%~dp0.."
where dub >nul 2>nul
if errorlevel 1 (
    echo ERROR: DUB was not found on PATH.
    exit /b 1
)
pushd "%~dp0" >nul
echo Building Aurora ISO (release)...
dub build --build=release
set "code=%errorlevel%"
popd >nul
exit /b %code%
