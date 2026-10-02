@echo off
REM Kill every instance, then bring up exactly one SUPERVISED app.
REM
REM The app is its own rebuild agent; a copy of the binary watches the run and
REM relaunches it after an unexpected exit (see shared/rebuild.d). It is started
REM with plain `start ""` and NOT `start /b`: /b attaches the new process to
REM this console, so the supervisor died with the batch that launched it.
setlocal
pushd "%~dp0.." >nul
set "state=%APPDATA%\Aurora OpenCode"

taskkill /IM aurora-opencode-pro.exe /F >nul 2>nul

:waitloop
2>nul (>>aurora-opencode-pro.exe echo off) && goto released
timeout /t 1 /nobreak >nul
goto waitloop
:released

start "" "%CD%\aurora-opencode-pro.exe" --aurora-rebuild-helper --no-rebuild --exe "%CD%\aurora-opencode-pro.exe" --dir "%CD%" --log "%state%\restart.log"

popd >nul
endlocal
