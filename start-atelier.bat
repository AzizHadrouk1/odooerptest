@echo off
setlocal
cd /d "%~dp0"

echo Atelier Meubles - demarrage 100%% automatique
echo WSL + Docker + Odoo (aucune commande a saisir)
echo Journal: "%~dp0logs\start-atelier.log"
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-atelier.ps1"
set "EXITCODE=%ERRORLEVEL%"

echo.
if "%EXITCODE%"=="99" (
  echo Demande UAC envoyee — continuez dans la fenetre administrateur.
  echo Cette fenetre se ferme dans 5 secondes...
  timeout /t 5 /nobreak >nul
  exit /b 0
)

if not "%EXITCODE%"=="0" (
  echo Echec du demarrage (code %EXITCODE%).
  echo Ouvrez le journal: "%~dp0logs\start-atelier.log"
  echo La fenetre reste ouverte 60 secondes...
  timeout /t 60 /nobreak >nul
) else (
  echo Termine avec succes. Odoo est ouvert dans le navigateur.
  echo La fenetre se ferme dans 8 secondes...
  timeout /t 8 /nobreak >nul
)

exit /b %EXITCODE%
