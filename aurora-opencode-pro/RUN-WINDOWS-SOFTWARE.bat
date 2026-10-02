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
echo Building Aurora OpenCode...
dub build --config=application --build=release
if errorlevel 1 (
    echo ERROR: the app did not build.
    popd >nul
    exit /b 1
)
echo Starting Aurora OpenCode with the software renderer (watched)...
REM The app is its own rebuild agent: a copy of the binary supervises the run
REM (see shared/rebuild.d). `--no-rebuild` skips DUB and only watches the app.
set AURORA_RENDERER=software
set "state=%APPDATA%\Aurora OpenCode"
"%~dp0aurora-opencode-pro.exe" --aurora-rebuild-helper --no-rebuild --exe "%~dp0aurora-opencode-pro.exe" --dir "%~dp0." --log "%state%\restart.log"
set "code=%errorlevel%"
popd >nul
exit /b %code%
