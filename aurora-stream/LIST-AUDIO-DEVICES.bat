@echo off
echo FFmpeg DirectShow microphone and capture devices
echo Aurora Stream uses these only for the Microphone dropdown.
echo Desktop audio is listed separately through Windows WASAPI.
echo This window is only a manual diagnostic fallback.
echo.
ffmpeg -hide_banner -list_devices true -f dshow -i dummy
pause
