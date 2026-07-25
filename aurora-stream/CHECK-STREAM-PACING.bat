@echo off
setlocal
pushd "%~dp0" >nul
set "code=0"

echo Aurora Stream A/V pacing diagnostic
echo This records three local 15-second Twitch-equivalent A/B/C test files.
echo A: FFmpeg synthetic audio
echo B: isolated 20 ms RTP silence helper
echo C: real event-driven WASAPI through the isolated RTP helper
echo Keep continuous motion and audible endpoint playback during every phase.
echo It does not stream and does not print or transmit stream keys.
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

where ffprobe >nul 2>nul
if errorlevel 1 (
    echo ERROR: ffprobe was not found on PATH. It normally comes with FFmpeg.
    set "code=1"
    goto :finish
)

dub run -- --pacing-test
set "code=%errorlevel%"

echo.
if "%code%"=="0" (
    echo Diagnostic complete.
    echo Report and local test files:
    echo %CD%\stream-pacing-diagnostic
) else (
    echo Diagnostic failed with exit code %code%.
)

:finish
popd >nul
echo.
pause
exit /b %code%
