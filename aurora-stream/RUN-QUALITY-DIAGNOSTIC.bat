@echo off
setlocal
cd /d "%~dp0"

echo Aurora Stream deterministic quality diagnostic
echo ==============================================
echo.
echo Close Aurora Stream before continuing.
echo The test will open a full-screen moving 1080p60 card and play a steady tone.
echo Keep Windows volume audible. Do not move the mouse or open other windows until it finishes.
echo No stream keys are read and no internet destination is contacted.
echo.
echo The complete result will be written to:
echo %CD%\aurora-stream-quality-diagnostic.txt
echo.

set "PYTHON_EXE="
where python >nul 2>nul && set "PYTHON_EXE=python"
if not defined PYTHON_EXE where py >nul 2>nul && set "PYTHON_EXE=py -3"
if not defined PYTHON_EXE (
    echo ERROR: Python 3 was not found in PATH.
    pause
    exit /b 2
)

%PYTHON_EXE% "%CD%\tests\run-quality-diagnostic.py"
set "RESULT=%ERRORLEVEL%"
echo.
if "%RESULT%"=="0" (
    echo Quality diagnostic finished.
    echo Upload this one file:
    echo %CD%\aurora-stream-quality-diagnostic.txt
) else (
    echo Quality diagnostic stopped with code %RESULT%.
    echo The partial report is still available at:
    echo %CD%\aurora-stream-quality-diagnostic.txt
)
echo.
pause
exit /b %RESULT%
