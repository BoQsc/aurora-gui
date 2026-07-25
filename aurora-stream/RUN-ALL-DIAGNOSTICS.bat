@echo off
setlocal EnableExtensions
pushd "%~dp0" >nul
set "REPORT=%CD%\aurora-stream-all-diagnostics.txt"
set "PYTHON="

if exist "%REPORT%" del /q "%REPORT%" >nul 2>nul

where python >nul 2>nul
if not errorlevel 1 set "PYTHON=python"
if not defined PYTHON (
    where py >nul 2>nul
    if not errorlevel 1 set "PYTHON=py -3"
)

if not defined PYTHON (
    >"%REPORT%" echo Aurora Stream full diagnostic
    >>"%REPORT%" echo =================================
    >>"%REPORT%" echo ERROR: Python 3 was not found on PATH.
    >>"%REPORT%" echo Install or expose Python 3, then run this file again.
    type "%REPORT%"
    goto :finish_error
)

echo Aurora Stream full one-click diagnostic
echo =======================================
echo.
echo Close Aurora Stream before continuing.
echo Keep a continuously moving game or desktop animation visible and keep desktop audio playing.
echo No stream keys are read, printed, or transmitted. Tests use local files and localhost only.
echo.
echo The complete result will be written to:
echo %REPORT%
echo.
timeout /t 5 /nobreak >nul

%PYTHON% "%CD%\tests\run-all-diagnostics.py" --root "%CD%" --report "%REPORT%"
set "CODE=%ERRORLEVEL%"

echo.
if exist "%REPORT%" (
    echo Diagnostic finished. Send this one file:
    echo %REPORT%
) else (
    echo ERROR: The diagnostic did not create its report.
)
echo.
pause
popd >nul
exit /b %CODE%

:finish_error
echo.
echo Diagnostic could not start. Send this one file:
echo %REPORT%
echo.
pause
popd >nul
exit /b 1
