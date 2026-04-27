@echo off
setlocal
set "SCRIPT=%~dp0CodexRebuild-RestoreCore.ps1"

if "%~1"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -StopRunningRebuild
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -BackupPath "%~1" -StopRunningRebuild
)

set "EXITCODE=%ERRORLEVEL%"
echo.
echo Exit code: %EXITCODE%
pause
exit /b %EXITCODE%
