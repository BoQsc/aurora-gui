@echo off
setlocal
pushd "%~dp0" >nul
echo Launching Aurora ISO with administrator rights (needed to write USB drives)...
powershell -NoProfile -Command "Start-Process -FilePath '%~dp0aurora-iso.exe' -Verb RunAs"
popd >nul
