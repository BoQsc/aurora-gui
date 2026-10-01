@echo off
setlocal
pushd "%~dp0" >nul
set "out=build\headless-smoke"
if not exist "%out%" mkdir "%out%"
where dmd >nul 2>nul
if errorlevel 1 (
    echo ERROR: DMD was not found on PATH.
    popd >nul
    exit /b 1
)
echo Building the Aurora Dimmer headless smoke test...
dmd -i -Isource -I..\vendor\aurora-d-0.4.5\source tests\headless_smoke.d -of="%out%\aurora-dimmer-smoke.exe" -Luser32.lib -Lgdi32.lib -Lshell32.lib -Lwininet.lib -Lole32.lib
set "code=%errorlevel%"
if not "%code%"=="0" goto :finish
echo Running the Aurora Dimmer headless smoke test...
"%out%\aurora-dimmer-smoke.exe"
set "code=%errorlevel%"
:finish
popd >nul
exit /b %code%
