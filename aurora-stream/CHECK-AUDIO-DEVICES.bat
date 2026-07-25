@echo off
setlocal
pushd "%~dp0" >nul
set "code=0"

echo Aurora Stream audio-device diagnostic
echo This only tests installed dependencies and writes audio-device-diagnostic.txt.
echo It does not install or change anything.
echo.

where dub >nul 2>nul
if errorlevel 1 (
    echo ERROR: DUB was not found on PATH. Install the D language toolchain first.
    set "code=1"
    goto :finish
)

where ffmpeg >nul 2>nul
if errorlevel 1 (
    echo ERROR: ffmpeg was not found on PATH.
    set "code=1"
    goto :finish
)

if exist audio-device-diagnostic.txt del /q audio-device-diagnostic.txt >nul 2>nul

dub run --single tests\audio-device-diagnostic.d
set "code=%errorlevel%"

echo.
if "%code%"=="0" (
    echo Diagnostic complete.
    echo Send or inspect: %CD%\audio-device-diagnostic.txt
) else (
    echo Diagnostic failed with exit code %code%.
)

:finish
popd >nul
echo.
pause
exit /b %code%
