@echo off
setlocal
pushd "%~dp0" >nul
echo Building a self-contained single-file Aurora ISO executable...
dub build --build=portable-single-exe
set "code=%errorlevel%"
popd >nul
exit /b %code%
