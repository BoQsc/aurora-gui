@echo off
setlocal

set "config=%~1"
set "label=%~2"
set "repo=%~dp0.."
set "aurora_d=%repo%\vendor\aurora-d-0.4.5"
set "code=0"

if "%config%"=="" (
    echo ERROR: Missing Aurora-D DUB configuration name.
    exit /b 1
)

if "%label%"=="" set "label=aurora-d %config%"

where dub >nul 2>nul
if errorlevel 1 (
    echo ERROR: DUB was not found on PATH. Install DMD or LDC with DUB first.
    exit /b 1
)

if not exist "%aurora_d%\dub.json" (
    echo ERROR: Aurora-D package was not found at "%aurora_d%".
    exit /b 1
)

pushd "%aurora_d%" >nul
echo Starting %label%...
echo The console will stay open while the app is running.
dub run --config=%config%
set "code=%errorlevel%"
if not "%code%"=="0" (
    echo.
    echo ERROR: %label% exited with code %code%.
)
popd >nul

exit /b %code%
