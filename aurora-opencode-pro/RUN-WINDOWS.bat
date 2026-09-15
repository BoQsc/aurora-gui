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
echo Building the restart helper...
REM The app's Restart button hands the rebuild to this standalone tool, so it
REM has to exist before the app needs it. Failure here is not fatal: the app
REM falls back to its generated PowerShell helper.
dub build --config=rebuilder --build=release >nul 2>nul
echo Starting Aurora OpenCode...
dub run --build=release
set "code=%errorlevel%"
popd >nul
exit /b %code%
