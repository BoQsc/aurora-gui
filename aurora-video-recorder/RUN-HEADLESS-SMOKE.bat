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
echo Building the Aurora Video Recorder headless smoke test...
dmd -i -O -Isource -I..\vendor\aurora-d-0.4.5\source tests\headless_smoke.d -of="%out%\aurora-video-recorder-smoke.exe" -Luser32.lib -Lgdi32.lib -Lshell32.lib -Lwininet.lib -Lole32.lib
set "code=%errorlevel%"
if not "%code%"=="0" goto :finish
echo Running the Aurora Video Recorder headless smoke test...
set "AURORA_RECORDER_EXE=%cd%\aurora-video-recorder.exe"
"%out%\aurora-video-recorder-smoke.exe" %*
set "code=%errorlevel%"
:finish
popd >nul
exit /b %code%
