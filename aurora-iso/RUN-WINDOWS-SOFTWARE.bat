@echo off
setlocal
set "repo=%~dp0.."
if not exist "%repo%\vendor\aurora-d-0.4.5\dub.json" (
    echo ERROR: Aurora-D package was not found at "%repo%\vendor\aurora-d-0.4.5".
    exit /b 1
)
pushd "%~dp0" >nul
echo Starting Aurora ISO (software renderer, no Vulkan)...
dub run -- --software
set "code=%errorlevel%"
popd >nul
exit /b %code%
