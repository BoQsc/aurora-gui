@echo off
rem Verify Aurora Write end to end.
rem
rem 1. Pure-unit tests for the concision engine and the model-reply parser.
rem 2. Headless GUI contract test (card placement, keys, apply, undo, status).
rem 3. Offline screenshot of the running surface for pixel review.
rem
rem The live provider check is deliberately separate: run
rem   aurora-write.exe --probe-llm "<sentence>" <word> probe.txt
setlocal
pushd "%~dp0" >nul
set "code=0"

echo [1/3] unit tests
if not exist build mkdir build
dmd -unittest -main -Isource -of=build\unit-tests.exe ^
    source\aurorawrite\concision.d source\aurorawrite\llmclient.d wininet.lib
if errorlevel 1 (set "code=1") else (build\unit-tests.exe || set "code=1")

echo [2/3] headless GUI contract test
dub build --config=smoke --build=debug --quiet
if errorlevel 1 (set "code=1") else (.\aurora-write-smoke.exe || set "code=1")

echo [3/3] offline screenshot
dub build --config=default --build=release --quiet
if errorlevel 1 (set "code=1") else (
    rem GuiWindow.saveScreenshot writes Netpbm P6; convert it for review.
    .\aurora-write.exe --screenshot artifacts\aurora-write-suggestions.ppm
    if errorlevel 1 (set "code=1") else (
        python -u -B tools\ppm-to-png.py artifacts\aurora-write-suggestions.ppm ^
            artifacts\aurora-write-suggestions.png || set "code=1"
    )
)

if "%code%"=="0" (echo ALL CHECKS PASSED) else (echo CHECKS FAILED)
popd >nul
exit /b %code%
