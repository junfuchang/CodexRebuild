@echo off
setlocal
set "SCRIPT=%~dp0CodexRebuild-EnablePluginsForApiKey.ps1"

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -StopRunningRebuild
set "EXITCODE=%ERRORLEVEL%"

echo.
echo Exit code: %EXITCODE%
pause
exit /b %EXITCODE%
