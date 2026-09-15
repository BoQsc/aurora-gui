@echo off
REM Stop the running app, wait for its image to be released, then start the
REM newly built one. Run detached because ending the app also ends anything
REM running inside it.
setlocal
pushd "%~dp0" >nul
set "state=%APPDATA%\Aurora OpenCode"
taskkill /IM aurora-opencode-pro.exe /F >nul 2>nul
:waitloop
2>nul (>>aurora-opencode-pro.exe echo off) && goto released
timeout /t 1 /nobreak >nul
goto waitloop
:released
bin\aurora-rebuilder.exe --exe "%~dp0aurora-opencode-pro.exe" --dir "%~dp0." --log "%state%\restart.log" --no-rebuild --run
popd >nul
endlocal
