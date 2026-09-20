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
echo Building the rebuild helper...
REM See RUN-WINDOWS.bat: the app's Rebuild button uses this standalone tool,
REM and the app is launched under it so its exit code is recorded.
dub build --config=rebuilder --build=release >nul 2>nul
echo Building Aurora OpenCode...
dub build --config=application --build=release
if errorlevel 1 (
    echo ERROR: the app did not build.
    popd >nul
    exit /b 1
)
echo Starting Aurora OpenCode with the software renderer (watched)...
set AURORA_RENDERER=software
bin\aurora-rebuilder.exe --exe "%~dp0aurora-opencode-pro.exe" --dir "%~dp0." --log "%APPDATA%\Aurora OpenCode\rebuild.log" --no-rebuild --run
set "code=%errorlevel%"
popd >nul
exit /b %code%
