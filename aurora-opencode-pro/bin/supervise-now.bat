@echo off
REM Kill every instance, then bring up exactly one SUPERVISED app.
REM
REM The supervisor is started with plain `start ""` and NOT `start /b`: /b
REM attaches the new process to this console, so the supervisor died with the
REM batch that launched it - which is why no supervisor was ever actually
REM running and unexpected-exits.log was never written.
setlocal
pushd "%~dp0.." >nul
set "state=%APPDATA%\Aurora OpenCode"

taskkill /IM aurora-opencode-pro.exe /F >nul 2>nul
taskkill /IM aurora-rebuilder.exe /F >nul 2>nul

:waitloop
2>nul (>>aurora-opencode-pro.exe echo off) && goto released
timeout /t 1 /nobreak >nul
goto waitloop
:released

start "" "%~dp0aurora-rebuilder.exe" --exe "%CD%\aurora-opencode-pro.exe" --dir "%CD%" --log "%state%\restart.log" --no-rebuild --supervise

popd >nul
endlocal
