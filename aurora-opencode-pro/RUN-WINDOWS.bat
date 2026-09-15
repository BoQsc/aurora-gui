@echo off
REM Start Aurora OpenCode under the supervisor.
REM
REM There is exactly one place that builds this app: the in-app Restart button,
REM which hands the work to bin\aurora-rebuilder.exe. This launcher therefore
REM does not build anything itself - doing so was a second copy of the same
REM operation that could disagree with the first.
REM
REM --supervise keeps the app running. If it stops without being asked to (a
REM crash, a fail-fast abort, a kill) it is started again automatically, and
REM the event is written to unexpected-exits.log next to the app's log with the
REM exit code and the last activity the app recorded. A clean exit - you closed
REM the window - ends the supervisor and shows "clean exit" in restart.log, so
REM a deliberate close is not mistaken for a fault.
setlocal
pushd "%~dp0" >nul
if not exist "bin\aurora-rebuilder.exe" (
    echo ERROR: bin\aurora-rebuilder.exe is missing.
    echo Build it once with: dub build --config=rebuilder --build=release
    popd >nul
    exit /b 1
)
echo Starting Aurora OpenCode (supervised: it restarts if it crashes)...
bin\aurora-rebuilder.exe --exe "%~dp0aurora-opencode-pro.exe" --dir "%~dp0." --log "%APPDATA%\Aurora OpenCode\restart.log" --no-rebuild --supervise
popd >nul
exit /b %errorlevel%
