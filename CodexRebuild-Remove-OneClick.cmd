@echo off
setlocal
set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
set "SCRIPT=%ROOT%\CodexRebuild-Remove.ps1"

if not exist "%SCRIPT%" (
  echo Missing script: %SCRIPT%
  set "EXITCODE=1"
  goto done
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Root "%ROOT%" -Execute
set "EXITCODE=%ERRORLEVEL%"

:done
echo.
echo Exit code: %EXITCODE%
pause
exit /b %EXITCODE%
