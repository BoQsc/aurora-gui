@echo off
setlocal
pushd "%~dp0" >nul
echo Running the Aurora RustDesk acceptance suite...
python build.py --test
set "code=%errorlevel%"
popd >nul
exit /b %code%
