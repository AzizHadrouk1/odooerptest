@echo off
setlocal
cd /d "%~dp0"

echo Atelier Meubles - demarrage en un clic
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-atelier.ps1"
set "EXITCODE=%ERRORLEVEL%"

echo.
if not "%EXITCODE%"=="0" (
  echo Echec du demarrage (code %EXITCODE%).
) else (
  echo Termine avec succes.
)

pause
exit /b %EXITCODE%
