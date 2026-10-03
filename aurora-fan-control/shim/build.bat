@echo off
REM Build wmi_shim.dll (the WBEM C shim) with MinGW-w64.
REM Produces ..\wmi_shim.dll next to the D executables.
setlocal
set GCC=C:\SysGCC\mingw64\bin\gcc.exe
if not exist "%GCC%" (
  echo MinGW-w64 gcc not found at %GCC%
  echo Edit GCC in this file to point at your gcc.exe.
  exit /b 1
)
"%GCC%" -shared -O2 -o "%~dp0..\wmi_shim.dll" "%~dp0wmi_shim.c" -lole32 -loleaut32 -lwbemuuid
