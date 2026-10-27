#Requires -Version 5.1
<#
.SYNOPSIS
  Fully automatic: enable WSL2 if needed, install Docker Desktop if needed,
  start the Atelier Meubles Odoo stack, open the UI, run the smoke test.
  Resumes automatically after reboot when Windows features require it.
#>
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$EngineTimeoutSec = 300
$StackTimeoutSec = 900
$PollSeconds = 5
$OdooUrl = "http://localhost:8069"
$TaskName = "AtelierMeublesAutoStart"
$ContinueFlag = Join-Path $Root ".atelier-continue-after-reboot"
$BatPath = Join-Path $Root "start-atelier.bat"

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-Elevation {
    Write-Step "Elevation administrateur requise (UAC) pour WSL / Docker"
    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    try {
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $args | Out-Null
    } catch {
        Write-Host "Elevation refusee. Acceptez la demande UAC pour continuer automatiquement." -ForegroundColor Red
        exit 1
    }
    exit 0
}

function Test-CommandExists([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Refresh-Path {
    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
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

function Get-WindowsFeatureState([string]$FeatureName) {
    try {
        $feat = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction Stop
        return [string]$feat.State
    } catch {
        return "Unknown"
    }
}

function Test-WslFeatureEnabled {
    $wsl = Get-WindowsFeatureState "Microsoft-Windows-Subsystem-Linux"
    $vm = Get-WindowsFeatureState "VirtualMachinePlatform"
    return ($wsl -eq "Enabled" -and $vm -eq "Enabled")
}

function Test-WslOperational {
    if (-not (Test-CommandExists "wsl")) {
        return $false
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $null = & wsl --status 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    # 0 = OK; some builds return 0 even with no distro. Non-zero usually means not ready.
    return ($code -eq 0)
}

function Register-ContinueAfterReboot {
    Write-Step "Planification de la reprise automatique apres redemarrage"
    "1" | Set-Content -LiteralPath $ContinueFlag -Encoding ASCII

    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -File `"$PSCommandPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "Tache planifiee '$TaskName' enregistree."
}

function Clear-ContinueAfterReboot {
    Remove-Item -LiteralPath $ContinueFlag -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Invoke-RebootToContinue {
    Register-ContinueAfterReboot
    Write-Host ""
    Write-Host "Redemarrage Windows dans 10 secondes pour activer WSL2..." -ForegroundColor Yellow
    Write-Host "Apres connexion, le demarrage Atelier Meubles reprendra tout seul."
    Start-Sleep -Seconds 10
    Restart-Computer -Force
    exit 0
}

function Ensure-Wsl {
    Write-Step "Verification WSL / VirtualMachinePlatform"

    $featuresOk = $false
    if (Test-IsAdmin) {
        $featuresOk = Test-WslFeatureEnabled
    } else {
        # Without admin, infer from wsl.exe behavior
        $featuresOk = Test-WslOperational
    }

    $needsEnable = -not $featuresOk
    $needsReboot = $false

    if ($needsEnable) {
        if (-not (Test-IsAdmin)) {
            Request-Elevation
        }

        Write-Step "Activation des composants Windows WSL + VirtualMachinePlatform"
        $features = @(
            "Microsoft-Windows-Subsystem-Linux",
            "VirtualMachinePlatform"
        )
        foreach ($name in $features) {
            $state = Get-WindowsFeatureState $name
            Write-Host "  $name : $state"
            if ($state -ne "Enabled") {
                $result = Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart
                if ($result.RestartNeeded) {
                    $needsReboot = $true
                }
                # DISM-style pending reboot
                if ($LASTEXITCODE -eq 3010) {
                    $needsReboot = $true
                }
            }
        }

        # Prefer official installer path when available (enables WSL + updates kernel)
        if (Test-CommandExists "wsl") {
            Write-Step "Installation / mise a jour WSL (sans distribution)"
            $prev = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            & wsl --install --no-distribution --web-download 2>&1 | Out-Host
            $wslInstallCode = $LASTEXITCODE
            $ErrorActionPreference = $prev
            # Common: success, already installed, or reboot required
            if ($wslInstallCode -eq 3010) {
                $needsReboot = $true
            }
        } else {
            $needsReboot = $true
        }

        if ($needsReboot -or -not (Test-WslFeatureEnabled)) {
            Invoke-RebootToContinue
        }
    }

    # Features on: ensure WSL2 default + kernel update
    if (-not (Test-IsAdmin) -and -not (Test-WslOperational)) {
        Request-Elevation
    }

    if (Test-CommandExists "wsl") {
        Write-Step "Configuration WSL 2"
        $prev = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        & wsl --set-default-version 2 2>&1 | Out-Host
        & wsl --update 2>&1 | Out-Host
        $status = & wsl --status 2>&1 | Out-String
        $ErrorActionPreference = $prev
        Write-Host $status

        if (-not (Test-WslOperational)) {
            Write-Host "WSL n'est pas encore operationnel — redemarrage requis." -ForegroundColor Yellow
            if (-not (Test-IsAdmin)) { Request-Elevation }
            Invoke-RebootToContinue
        }
        Write-Host "WSL pret."
    } else {
        Write-Host "wsl.exe introuvable apres activation — redemarrage requis." -ForegroundColor Yellow
        if (-not (Test-IsAdmin)) { Request-Elevation }
        Invoke-RebootToContinue
    }
}

function Set-DockerDesktopDefaults {
    $dockerAppData = Join-Path $env:APPDATA "Docker"
    if (-not (Test-Path -LiteralPath $dockerAppData)) {
        New-Item -ItemType Directory -Path $dockerAppData -Force | Out-Null
    }

    $settingsJson = Join-Path $dockerAppData "settings.json"
    if (-not (Test-Path -LiteralPath $settingsJson)) {
        $settings = @{
            analyticsEnabled     = $false
            autoStart            = $true
            displayedTutorial    = $true
            wslEngineEnabled     = $true
            useWindowsContainers = $false
        }
        $settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $settingsJson -Encoding UTF8
        Write-Host "settings.json Docker preconfigure (WSL2)."
    }

    $storeJson = Join-Path $dockerAppData "settings-store.json"
    if (-not (Test-Path -LiteralPath $storeJson)) {
        $store = @{
            AutoStart            = $true
            DisplayedOnboarding  = $true
            EnableDefaultDockerSocket = $true
        }
        $store | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $storeJson -Encoding UTF8
    }
}

function Install-DockerDesktop {
    Write-Step "Docker introuvable — installation de Docker Desktop via winget"
    if (-not (Test-CommandExists "winget")) {
        Write-Host "winget est introuvable. Impossible d'installer Docker automatiquement." -ForegroundColor Red
        Write-Host "https://www.docker.com/products/docker-desktop/"
        exit 1
    }

    if (-not (Test-IsAdmin)) {
        Request-Elevation
    }

    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & winget install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements --disable-interactivity
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev

    # 0 success, -1978335189 / other codes sometimes mean already installed
    if ($code -ne 0 -and -not (Get-DockerDesktopPath)) {
        Write-Host "Echec de l'installation Docker Desktop (code $code)." -ForegroundColor Red
        exit 1
    }

    Refresh-Path
    Set-DockerDesktopDefaults
    Write-Host "Docker Desktop installe."
}

function Start-DockerDesktopIfNeeded {
    if (Test-DockerCli) {
        return
    }

    Set-DockerDesktopDefaults

    $desktop = Get-DockerDesktopPath
    if (-not $desktop) {
        Write-Host "Docker Desktop.exe introuvable apres installation." -ForegroundColor Red
        exit 1
    }

    Write-Step "Demarrage de Docker Desktop"
    # -AcceptEula is supported by recent Docker Desktop builds; ignore if unknown
    try {
        Start-Process -FilePath $desktop -ArgumentList "-AcceptEula" | Out-Null
    } catch {
        Start-Process -FilePath $desktop | Out-Null
    }
}

function Wait-DockerEngine {
    Write-Step "Attente du moteur Docker (max ${EngineTimeoutSec}s)"
    $deadline = (Get-Date).AddSeconds($EngineTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Refresh-Path
        if (Test-DockerCli) {
            Write-Host "Moteur Docker pret."
            return
        }
        # Keep trying to launch Desktop if it crashed / not yet started
        if (-not (Get-Process -Name "Docker Desktop" -ErrorAction SilentlyContinue)) {
            $desktop = Get-DockerDesktopPath
            if ($desktop) {
                try { Start-Process -FilePath $desktop -ArgumentList "-AcceptEula" | Out-Null } catch { }
            }
        }
        Start-Sleep -Seconds $PollSeconds
        Write-Host "  ... Docker n'est pas encore pret"
    }

    Write-Host "Le moteur Docker n'est pas pret a temps." -ForegroundColor Red
    Write-Host "Verifiez Docker Desktop (WSL2 active) puis relancez start-atelier.bat."
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
        Write-Host ".env cree depuis .env.example."
    } else {
        Write-Host ".env deja present (non ecrase)."
    }
}

function Show-PasswordHintIfNeeded {
    $logs = & docker compose logs --tail=80 init db 2>$null | Out-String
    if ($logs -match "password authentication failed for user `"odoo`"") {
        Write-Host ""
        Write-Host "Echec d'authentification PostgreSQL : volume cree avec un ancien mot de passe." -ForegroundColor Yellow
        Write-Host "Pour repartir de zero (efface les donnees) :"
        Write-Host "  docker compose down -v"
        Write-Host "  puis relancez start-atelier.bat"
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

    $smokeCode = [System.IO.File]::ReadAllText($smokePath)
    if ($smokeCode.Length -gt 0 -and [int][char]$smokeCode[0] -eq 0xFEFF) {
        $smokeCode = $smokeCode.Substring(1)
    }
    $tmpSmoke = Join-Path $env:TEMP "atelier_meubles_smoke_test.py"
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tmpSmoke, $smokeCode, $utf8NoBom)

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = cmd /c "type `"$tmpSmoke`" | docker compose run -T --rm init odoo shell -d atelier_meubles" 2>&1
    $composeExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    Remove-Item -LiteralPath $tmpSmoke -ErrorAction SilentlyContinue

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
Write-Host "Atelier Meubles — demarrage 100% automatique" -ForegroundColor Green

if (Test-Path -LiteralPath $ContinueFlag) {
    Write-Host "Reprise apres redemarrage detectee."
}

Ensure-Wsl

Refresh-Path
if (-not (Test-CommandExists "docker") -or -not (Get-DockerDesktopPath)) {
    Install-DockerDesktop
    Refresh-Path
} elseif (-not (Test-DockerCompose)) {
    # compose plugin missing — reinstall / repair Desktop
    Install-DockerDesktop
    Refresh-Path
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

Clear-ContinueAfterReboot

Write-Host ""
Write-Host "Pret. Odoo : $OdooUrl  (admin / admin)" -ForegroundColor Green
Write-Host "Arret sans effacer les donnees : docker compose down"
exit 0
