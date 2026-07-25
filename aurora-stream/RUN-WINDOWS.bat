@echo off
echo Aurora Stream 0.4.9
setlocal
pushd "%~dp0" >nul
set "code=0"

where dub >nul 2>nul
if errorlevel 1 (
    echo ERROR: DUB was not found on PATH.
    set "code=1"
    goto :finish
)
where ffmpeg >nul 2>nul
if errorlevel 1 (
    echo ERROR: ffmpeg was not found on PATH.
    set "code=1"
    goto :finish
)

if exist aurora-stream-startup.log del /q aurora-stream-startup.log >nul 2>nul

echo Starting Aurora Stream...
echo The console will stay open while the broadcaster is running.
dub run
set "code=%errorlevel%"
if not "%code%"=="0" (
    echo.
    echo ERROR: Aurora Stream exited with code %code%.
    if exist aurora-stream-startup.log type aurora-stream-startup.log
)

:finish
popd >nul
exit /b %code%
