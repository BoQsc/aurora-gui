@echo off
echo Aurora Stream 0.60.0
setlocal
pushd "%~dp0" >nul
set "code=0"

where dub >nul 2>nul
if errorlevel 1 (
    echo ERROR: DUB was not found on PATH. Install DMD or LDC with DUB first.
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

echo Cleaning Aurora Stream...
dub clean
set "code=%errorlevel%"
if not "%code%"=="0" goto :finish

echo Building and starting Aurora Stream...
echo The console will stay open while the broadcaster is running.
dub run
set "code=%errorlevel%"
if not "%code%"=="0" call :show_failure
goto :finish

:show_failure
echo.
echo ERROR: Aurora Stream exited with code %code%.
if exist aurora-stream-startup.log (
    echo.
    echo Startup diagnostic:
    type aurora-stream-startup.log
)
echo.
echo Try RUN-WINDOWS-SOFTWARE.bat if the failure is related to Vulkan or the display driver.
exit /b 0

:finish
popd >nul
exit /b %code%
