@echo off
REM Stop the running app, wait for its image to be released, then start the
REM newly built one under its own rebuild agent (--no-rebuild only supervises).
REM Run detached because ending the app also ends anything running inside it.
setlocal
pushd "%~dp0.." >nul
set "state=%APPDATA%\Aurora OpenCode"
taskkill /IM aurora-opencode-pro.exe /F >nul 2>nul
:waitloop
2>nul (>>aurora-opencode-pro.exe echo off) && goto released
timeout /t 1 /nobreak >nul
goto waitloop
:released
"%CD%\aurora-opencode-pro.exe" --aurora-rebuild-helper --no-rebuild --exe "%CD%\aurora-opencode-pro.exe" --dir "%CD%" --log "%state%\restart.log"
popd >nul
endlocal
