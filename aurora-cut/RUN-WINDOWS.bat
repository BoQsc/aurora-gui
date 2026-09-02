@echo off
echo Aurora Cut 0.60.0
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

where ffprobe >nul 2>nul
if errorlevel 1 (
    echo ERROR: ffprobe was not found on PATH.
    set "code=1"
    goto :finish
)

where ffplay >nul 2>nul
if errorlevel 1 echo WARNING: ffplay was not found; visual preview works, but preview audio is unavailable.

if exist aurora-cut-startup.log del /q aurora-cut-startup.log >nul 2>nul

echo Starting Aurora Cut...
echo The console will stay open while the editor is running.
dub run
set "code=%errorlevel%"
if not "%code%"=="0" (
    echo.
    echo ERROR: Aurora Cut exited with code %code%.
    if exist aurora-cut-startup.log (
        echo.
        echo Startup diagnostic:
        type aurora-cut-startup.log
    )
    echo.
    echo Try RUN-WINDOWS-SOFTWARE.bat if the failure is related to a Vulkan or display driver.
)

:finish
popd >nul
exit /b %code%
