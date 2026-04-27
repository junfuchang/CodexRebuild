@echo off
setlocal
set "ROOT=%~dp0"
set "SCRIPT=%~dp0CodexRebuild-UpdateCore.ps1"

if "%~1"=="" (
  if not exist "%ROOT%codex-x86_64-pc-windows-msvc.exe*" (
    echo No Codex core release package was found in:
    echo   %ROOT%
    echo.
    echo Download the latest codex-x86_64-pc-windows-msvc.exe.zip from:
    echo   https://github.com/openai/codex/releases
    echo.
    echo Put the zip file in the current script directory, then run again:
    echo   %ROOT%
    echo.
    echo Accepted local package names:
    echo   codex-x86_64-pc-windows-msvc.exe*
    echo   codex-x86_64-pc-windows-msvc.exe*.zip
    echo.
    echo Or drag/drop a release folder or zip onto this CMD file.
    set "EXITCODE=1"
    goto done
  )
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -StopRunningRebuild
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -SourcePath "%~1" -StopRunningRebuild
)

set "EXITCODE=%ERRORLEVEL%"

:done
echo.
echo Exit code: %EXITCODE%
pause
exit /b %EXITCODE%
