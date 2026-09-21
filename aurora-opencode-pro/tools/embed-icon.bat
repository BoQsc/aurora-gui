@echo off
REM Append the app icon as a PE .rsrc section so Explorer and the taskbar show
REM it for the built exe. The runtime window icon does NOT depend on this (the
REM .ico bytes are embedded in the binary); this step is best-effort: a missing
REM Python, a missing icon, or a still-locked target only skips it, so a build
REM is never failed by icon work.
setlocal
set "root=%~dp0.."
set "ico=%root%\assets\aurora-opencode-pro.ico"
set "patch=%~dp0..\..\scripts\patch-pe-icon.py"
if not exist "%ico%" exit /b 0
if not exist "%patch%" exit /b 0
where python >nul 2>nul || exit /b 0

rem Patch the exe DUB just built (named after the configuration's targetName,
rem which DUB exports as DUB_TARGET_NAME). A locked target (the running app) is
rem skipped by the failed write, and re-patching is idempotent anyway.
set "name=aurora-opencode-pro"
if defined DUB_TARGET_NAME set "name=%DUB_TARGET_NAME%"
if exist "%root%\%name%.exe" python "%patch%" "%ico%" "%root%\%name%.exe"
exit /b 0
