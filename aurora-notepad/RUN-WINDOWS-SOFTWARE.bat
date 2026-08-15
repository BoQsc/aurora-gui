@echo off
setlocal
set "repo=%~dp0.."
if not exist "%repo%\vendor\aurora-d-0.4.5\dub.json" (
    echo ERROR: Aurora-D package was not found at "%repo%\vendor\aurora-d-0.4.5".
    exit /b 1
)
where dub >nul 2>nul
if errorlevel 1 (
    echo ERROR: DUB was not found on PATH. Install DMD or LDC with DUB first.
    exit /b 1
)
pushd "%~dp0" >nul
echo Starting Aurora Notepad with the software renderer...
set AURORA_RENDERER=software
dub run --build=release
set "code=%errorlevel%"
popd >nul
exit /b %code%
