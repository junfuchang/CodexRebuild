@echo off
setlocal
set "ROOT=%~dp0"
set "REBUILD=%ROOT%CodexRebuild-Rebuild.ps1"
set "TEST=%ROOT%CodexRebuild-Test.ps1"

if not exist "%REBUILD%" (
  echo Missing script: %REBUILD%
  set "EXITCODE=1"
  goto done
)

if not exist "%TEST%" (
  echo Missing script: %TEST%
  set "EXITCODE=1"
  goto done
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%REBUILD%" -StopRunningRebuild -NoCoreReplacement
set "EXITCODE=%ERRORLEVEL%"
if not "%EXITCODE%"=="0" goto done

powershell -NoProfile -ExecutionPolicy Bypass -File "%TEST%" -StopExisting
set "EXITCODE=%ERRORLEVEL%"

:done
echo.
echo Exit code: %EXITCODE%
pause
exit /b %EXITCODE%
