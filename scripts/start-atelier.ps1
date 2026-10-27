#Requires -Version 5.1
<#
.SYNOPSIS
  Checks Docker, starts the Atelier Meubles Odoo stack, opens the UI, runs the smoke test.
#>
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$EngineTimeoutSec = 180
$StackTimeoutSec = 900
$PollSeconds = 5
$OdooUrl = "http://localhost:8069"

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Test-DockerCli {
    try {
        $null = & docker version --format "{{.Server.Version}}" 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Test-DockerCompose {
    try {
        $null = & docker compose version 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Test-CommandExists([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-DockerDesktopPath {
    $candidates = @(
        "${env:ProgramFiles}\Docker\Docker\Docker Desktop.exe",
        "${env:ProgramFiles(x86)}\Docker\Docker\Docker Desktop.exe",
        "$env:LOCALAPPDATA\Docker\Docker Desktop.exe"
    )
    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            return $path
        }
    }
    return $null
}

function Install-DockerDesktop {
    Write-Step "Docker introuvable — installation de Docker Desktop via winget"
    if (-not (Test-CommandExists "winget")) {
        Write-Host "winget est introuvable. Installez Docker Desktop manuellement :" -ForegroundColor Red
        Write-Host "https://www.docker.com/products/docker-desktop/"
        exit 1
    }

    & winget install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Echec de l'installation Docker Desktop (code $LASTEXITCODE)." -ForegroundColor Red
        Write-Host "Installez-le manuellement : https://www.docker.com/products/docker-desktop/"
        exit 1
    }

    Write-Host "Docker Desktop a ete installe. Si c'est la premiere fois, acceptez l'assistant,"
    Write-Host "activez les conteneurs Linux / WSL2, puis redemarrez si demande."

    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
}

function Start-DockerDesktopIfNeeded {
    if (Test-DockerCli) {
        return
    }

    $desktop = Get-DockerDesktopPath
    if (-not $desktop) {
        Write-Host "Docker Desktop.exe introuvable apres installation." -ForegroundColor Red
        Write-Host "Ouvrez Docker Desktop depuis le menu Demarrer, terminez la configuration, puis relancez ce script."
        exit 1
    }

    Write-Step "Demarrage de Docker Desktop"
    Start-Process -FilePath $desktop | Out-Null
}

function Wait-DockerEngine {
    Write-Step "Attente du moteur Docker (max ${EngineTimeoutSec}s)"
    $deadline = (Get-Date).AddSeconds($EngineTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-DockerCli) {
            Write-Host "Moteur Docker pret."
            return
        }
        Start-Sleep -Seconds $PollSeconds
        Write-Host "  ... Docker n'est pas encore pret"
    }

    Write-Host "Le moteur Docker n'est pas pret a temps." -ForegroundColor Red
    Write-Host "Ouvrez Docker Desktop, acceptez l'assistant (WSL2 / Linux containers),"
    Write-Host "redemarrez si necessaire, puis relancez start-atelier.bat."
    exit 1
}

function Ensure-EnvFile {
    Write-Step "Verification de .env"
    $envPath = Join-Path $Root ".env"
    $examplePath = Join-Path $Root ".env.example"
    if (-not (Test-Path -LiteralPath $envPath)) {
        if (-not (Test-Path -LiteralPath $examplePath)) {
            Write-Host ".env.example introuvable." -ForegroundColor Red
            exit 1
        }
        Copy-Item -LiteralPath $examplePath -Destination $envPath
        Write-Host ".env cree depuis .env.example — modifiez ODOO_DB_PASSWORD si besoin."
    } else {
        Write-Host ".env deja present (non ecrase)."
    }
}

function Show-PasswordHintIfNeeded {
    $logs = & docker compose logs --tail=80 init db 2>$null | Out-String
    if ($logs -match "password authentication failed for user `"odoo`"") {
        Write-Host ""
        Write-Host "Echec d'authentification PostgreSQL : le volume a ete cree avec un ancien mot de passe." -ForegroundColor Yellow
        Write-Host "Remettez l'ancien ODOO_DB_PASSWORD dans .env, ou repartez de zero :"
        Write-Host "  docker compose down -v"
        Write-Host "  docker compose up --build -d"
    }
}

function Wait-StackReady {
    Write-Step "Attente de l'installation Odoo / module atelier_meubles (max ${StackTimeoutSec}s)"
    $deadline = (Get-Date).AddSeconds($StackTimeoutSec)

    while ((Get-Date) -lt $deadline) {
        $ps = & docker compose ps --format json 2>$null
        $initFailed = $false
        $odooUp = $false

        if ($ps) {
            foreach ($line in @($ps)) {
                if (-not $line) { continue }
                try {
                    $row = $line | ConvertFrom-Json
                } catch {
                    continue
                }
                $name = [string]$row.Service
                $state = [string]$row.State
                $status = [string]$row.Status
                if ($name -eq "init" -and $state -eq "exited") {
                    $exitCode = 1
                    try {
                        $inspect = & docker inspect --format "{{.State.ExitCode}}" $row.ID 2>$null
                        if ($inspect -ne $null -and $inspect -ne "") { $exitCode = [int]$inspect }
                    } catch { }
                    if ($exitCode -ne 0) { $initFailed = $true }
                }
                if ($name -eq "odoo" -and ($state -eq "running" -or $status -match "Up")) {
                    $odooUp = $true
                }
            }
        }

        if (-not $odooUp -or -not $initFailed) {
            $plain = & docker compose ps 2>$null | Out-String
            if ($plain -match "odoo\s+.*\sUp") { $odooUp = $true }
            if ($plain -match "init\s+.*Exit [1-9]") { $initFailed = $true }
        }

        if ($initFailed) {
            Write-Host "Le service init a echoue." -ForegroundColor Red
            & docker compose logs --tail=50 init
            Show-PasswordHintIfNeeded
            exit 1
        }

        if ($odooUp) {
            $query = "SELECT state FROM ir_module_module WHERE name = 'atelier_meubles';"
            $result = & docker compose exec -T db psql -U odoo -d atelier_meubles -tAc $query 2>$null
            if ($LASTEXITCODE -eq 0 -and ($result -match "installed")) {
                Write-Host "Module atelier_meubles installe, Odoo demarre."
                return
            }
        }

        Start-Sleep -Seconds $PollSeconds
        Write-Host "  ... installation / demarrage en cours"
    }

    Write-Host "Delai depasse en attendant Odoo." -ForegroundColor Red
    & docker compose ps
    & docker compose logs --tail=50 init odoo
    Show-PasswordHintIfNeeded
    exit 1
}

function Invoke-SmokeTest {
    Write-Step "Execution du smoke test"
    $smokePath = Join-Path $Root "scripts\smoke_test.py"
    if (-not (Test-Path -LiteralPath $smokePath)) {
        Write-Host "scripts\smoke_test.py introuvable — smoke test ignore." -ForegroundColor Yellow
        return
    }

    # Strip UTF-8 BOM — Odoo shell rejects U+FEFF as a SyntaxError
    $smokeCode = [System.IO.File]::ReadAllText($smokePath)
    if ($smokeCode.Length -gt 0 -and [int][char]$smokeCode[0] -eq 0xFEFF) {
        $smokeCode = $smokeCode.Substring(1)
    }

    # docker compose writes progress to stderr; do not treat that as a terminating error
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = $smokeCode | & docker compose run -T --rm init odoo shell -d atelier_meubles 2>&1
    $composeExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEap

    $text = ($output | ForEach-Object { "$_" }) -join "`n"
    Write-Host $text

    if ($composeExit -eq 0 -and $text -match "OK: 2 meubles") {
        Write-Host "Smoke test OK." -ForegroundColor Green
    } else {
        Write-Host "Smoke test en echec ou resultat inattendu." -ForegroundColor Red
        exit 1
    }
}

# --- main ---
Write-Host "Atelier Meubles — demarrage / test ERP" -ForegroundColor Green

if (-not (Test-CommandExists "docker")) {
    Install-DockerDesktop
} elseif (-not (Test-DockerCompose)) {
    Write-Host "docker est present mais 'docker compose' est indisponible." -ForegroundColor Red
    Write-Host "Installez / mettez a jour Docker Desktop, puis relancez."
    exit 1
}

Start-DockerDesktopIfNeeded
Wait-DockerEngine

if (-not (Test-DockerCompose)) {
    Write-Host "'docker compose' est toujours indisponible." -ForegroundColor Red
    exit 1
}

Ensure-EnvFile

Write-Step "docker compose up --build -d"
& docker compose up --build -d
if ($LASTEXITCODE -ne 0) {
    Write-Host "Echec de docker compose up." -ForegroundColor Red
    Show-PasswordHintIfNeeded
    exit 1
}

Wait-StackReady

Write-Step "Ouverture de $OdooUrl"
Start-Process $OdooUrl
Write-Host "Connexion initiale : admin / admin"

Invoke-SmokeTest

Write-Host ""
Write-Host "Pret. Odoo : $OdooUrl  (admin / admin)" -ForegroundColor Green
Write-Host "Arret sans effacer les donnees : docker compose down"
exit 0
