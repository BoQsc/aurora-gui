@echo off
REM Start Aurora OpenCode under the watchdog.
REM
REM There is exactly one place that builds this app: the in-app Restart button,
REM which hands the work to bin\aurora-rebuilder.exe. This launcher therefore
REM does not build anything itself - doing so was a second copy of the same
REM operation that could disagree with the first.
REM
REM The app is started as the rebuilder's child (--run) rather than directly,
REM because a fail-fast death (heap corruption, stack cookie, abort) never
REM reaches the app's exception filter: the app cannot report it, and the log
REM just stops. Only a parent sees the exit code, and that code names the
REM cause. Remove --run to launch the app unwatched.
setlocal
pushd "%~dp0" >nul
if not exist "bin\aurora-rebuilder.exe" (
    echo ERROR: bin\aurora-rebuilder.exe is missing.
    echo Build it once with: dub build --config=rebuilder --build=release
    popd >nul
    exit /b 1
)
echo Starting Aurora OpenCode...
bin\aurora-rebuilder.exe --exe "%~dp0aurora-opencode-pro.exe" --dir "%~dp0." --log "%APPDATA%\Aurora OpenCode\restart.log" --no-rebuild --run
popd >nul
exit /b %errorlevel%
