@echo off
setlocal
cd /d "%~dp0"

echo Atelier Meubles - demarrage 100%% automatique
echo WSL + Docker + Odoo (aucune commande a saisir)
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-atelier.ps1"
set "EXITCODE=%ERRORLEVEL%"

echo.
if not "%EXITCODE%"=="0" (
  echo Echec du demarrage (code %EXITCODE%).
  echo La fenetre se ferme dans 20 secondes...
  timeout /t 20 /nobreak >nul
) else (
  echo Termine avec succes. Odoo est ouvert dans le navigateur.
  echo La fenetre se ferme dans 8 secondes...
  timeout /t 8 /nobreak >nul
)

exit /b %EXITCODE%
