#Requires -Version 5.1
<#
.SYNOPSIS
  Fully automatic Atelier Meubles launcher for a clean Windows PC:
  enable WSL2, install Docker Desktop, start Odoo, open UI, smoke test.
  Resumes after reboot. Writes logs\start-atelier.log on every run.
#>
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $Root

$EngineTimeoutSec = 420
$StackTimeoutSec = 900
$PollSeconds = 5
$OdooUrl = "http://localhost:8069"
$TaskName = "AtelierMeublesAutoStart"
$ContinueFlag = Join-Path $Root ".atelier-continue-after-reboot"
$LogDir = Join-Path $Root "logs"
$LogFile = Join-Path $LogDir "start-atelier.log"
$LogFileHost = Join-Path $LogDir ("start-atelier-{0}.log" -f $env:COMPUTERNAME)
# Exit code meaning: elevated child was started; parent should not report success/failure of the stack.
$ExitElevatedRelaunch = 99

function Ensure-LogDir {
    if (-not (Test-Path -LiteralPath $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
}

function Convert-ToLogText([object]$Value) {
    # wsl.exe often emits UTF-16; PowerShell may keep NUL bytes -> "D e f a u l t"
    $text = ($Value | ForEach-Object { "$_" }) -join "`n"
    return ($text -replace "`0", "").Trim()
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $clean = Convert-ToLogText $Message
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $clean
    foreach ($path in @($LogFile, $LogFileHost)) {
        Add-Content -LiteralPath $path -Value $line -Encoding UTF8
    }
}

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
    Write-Log $Message
}

function Write-Info([string]$Message) {
    Write-Host $Message
    Write-Log $Message
}

function Write-Warn([string]$Message) {
    Write-Host $Message -ForegroundColor Yellow
    Write-Log $Message "WARN"
}

function Write-Err([string]$Message) {
    Write-Host $Message -ForegroundColor Red
    Write-Log $Message "ERROR"
}

function Fail([string]$Message, [int]$Code = 1) {
    Write-Err $Message
    Write-Err "Journal: $LogFile"
    Write-Err "Aussi: $LogFileHost"
    Write-Err "Pour GitHub: git add logs && git commit -m `"log failure`" && git push"
    try { Start-Process notepad.exe $LogFile } catch { }
    exit $Code
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-Elevation {
    Write-Step "Elevation administrateur requise (acceptez UAC)"
    $argList = @(
        "-NoProfile"
        "-ExecutionPolicy", "Bypass"
        "-File", "`"$PSCommandPath`""
    )
    try {
        Start-Process -FilePath "powershell.exe" -Verb RunAs -WorkingDirectory $Root -ArgumentList $argList | Out-Null
    } catch {
        Fail "Elevation refusee. Acceptez la demande UAC, puis relancez start-atelier.bat."
    }
    exit $ExitElevatedRelaunch
}

function Test-CommandExists([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [switch]$IgnoreExitCode
    )
    Write-Log ("RUN: {0} {1}" -f $FilePath, ($ArgumentList -join " "))
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & $FilePath @ArgumentList 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    $text = ($output | ForEach-Object { "$_" }) -join "`n"
    if ($text) {
        Write-Host $text
        Write-Log $text
    }
    Write-Log ("EXIT: $code")
    if (-not $IgnoreExitCode -and $code -ne 0) {
        return $code
    }
    return $code
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
        # Fallback DISM parse
        try {
            $dism = & dism.exe /online /Get-FeatureInfo /FeatureName:$FeatureName 2>&1 | Out-String
            if ($dism -match "State\s*:\s*Enabled") { return "Enabled" }
            if ($dism -match "State\s*:\s*Disabled") { return "Disabled" }
        } catch { }
        return "Unknown"
    }
}

function Enable-WindowsFeatureCompat([string]$FeatureName) {
    Write-Info "Activation de $FeatureName..."
    try {
        $result = Enable-WindowsOptionalFeature -Online -FeatureName $FeatureName -All -NoRestart -ErrorAction Stop
        if ($result.RestartNeeded) { return $true }
        return $false
    } catch {
        Write-Warn "Enable-WindowsOptionalFeature a echoue: $($_.Exception.Message)"
        $code = Invoke-Native -FilePath "dism.exe" -ArgumentList @("/online", "/enable-feature", "/featurename:$FeatureName", "/all", "/norestart") -IgnoreExitCode
        if ($code -eq 3010) { return $true }
        if ($code -ne 0 -and $code -ne 3010) {
            Write-Warn "DISM code $code pour $FeatureName"
        }
        return ($code -eq 3010)
    }
}

function Test-WslOperational {
    if (-not (Test-CommandExists "wsl")) {
        return $false
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    # Several signals — Windows builds disagree on exit codes.
    $statusRaw = & wsl --status 2>&1
    $statusCode = $LASTEXITCODE
    $listRaw = & wsl -l -q 2>&1
    $listCode = $LASTEXITCODE
    $ErrorActionPreference = $prev

    $statusOut = Convert-ToLogText $statusRaw
    $listOut = Convert-ToLogText $listRaw
    Write-Log ("wsl --status exit=$statusCode :: $statusOut")
    Write-Log ("wsl -l -q exit=$listCode :: $listOut")

    if ($statusOut -match "WslRegisterDistribution failed|0x800|The Windows Subsystem for Linux requires|n'est pas activ|not enabled|has not been installed") {
        return $false
    }
    if ($statusCode -eq 0) { return $true }
    # On some builds --status fails but listing works once features are on
    if ($listCode -eq 0) { return $true }
    # Features enabled + wsl.exe present often enough for Docker's own distro install
    if ((Get-WindowsFeatureState "Microsoft-Windows-Subsystem-Linux") -eq "Enabled" -and
        (Get-WindowsFeatureState "VirtualMachinePlatform") -eq "Enabled") {
        if ($statusOut -match "Default Version:\s*2" -or $statusOut -match "version par defaut\s*:\s*2") {
            return $true
        }
    }
    return $false
}

function Test-CpuVirtualization {
    # Win32_Processor.VirtualizationFirmwareEnabled is often false under Hyper-V/WSL even when VT-x works.
    try {
        $hv = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($hv -and $hv.HypervisorPresent) {
            Write-Info "Hyperviseur detecte (virtualisation OK pour WSL2/Docker)."
            return $true
        }
    } catch { }
    try {
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        if ($cpu -and ($cpu.VirtualizationFirmwareEnabled -eq $true)) {
            return $true
        }
        if ($cpu -and ($cpu.VirtualizationFirmwareEnabled -eq $false)) {
            Write-Warn "La virtualisation CPU peut etre desactivee dans le BIOS/UEFI (Intel VT-x / AMD-V)."
            Write-Warn "Si Docker/WSL echouent ensuite, activez-la dans le BIOS."
            return $false
        }
    } catch { }
    return $true
}

function Register-ContinueAfterReboot {
    Write-Step "Planification de la reprise automatique apres redemarrage"
    "1" | Set-Content -LiteralPath $ContinueFlag -Encoding ASCII

    $psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -File `"$PSCommandPath`""
    $userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    try {
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $psArgs -WorkingDirectory $Root
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
        $principal = New-ScheduledTaskPrincipal -UserId $userId -RunLevel Highest -LogonType Interactive
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Write-Info "Tache planifiee '$TaskName' OK ($userId)."
    } catch {
        Write-Warn "Tache planifiee echouee: $($_.Exception.Message) — fallback RunOnce."
    }

    # Backup: RunOnce for current user
    try {
        $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Name "AtelierMeublesAutoStart" -Value $cmd -Force
        Write-Info "RunOnce registre OK."
    } catch {
        Write-Warn "RunOnce echoue: $($_.Exception.Message)"
    }
}

function Clear-ContinueAfterReboot {
    Remove-Item -LiteralPath $ContinueFlag -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    try {
        Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Name "AtelierMeublesAutoStart" -ErrorAction SilentlyContinue
    } catch { }
}

function Invoke-RebootToContinue {
    Register-ContinueAfterReboot
    Write-Warn "Redemarrage Windows dans 15 secondes pour activer WSL2 / Docker..."
    Write-Info "Apres connexion Windows, Atelier Meubles reprendra automatiquement."
    Write-Info "Journal: $LogFile"
    Start-Sleep -Seconds 15
    Restart-Computer -Force
    exit 0
}

function Install-WslWithFallbacks {
    Write-Step "Installation / configuration WSL"
    $attempts = @(
        @("--install", "--no-distribution", "--web-download"),
        @("--install", "--no-distribution"),
        @("--install", "--web-download"),
        @("--install")
    )
    foreach ($args in $attempts) {
        Write-Info ("Essai: wsl " + ($args -join " "))
        $code = Invoke-Native -FilePath "wsl.exe" -ArgumentList $args -IgnoreExitCode
        if ($code -eq 0 -or $code -eq 3010) {
            return $code
        }
    }
    return 1
}

function Ensure-Wsl {
    Write-Step "Verification WSL / VirtualMachinePlatform"

    $os = Get-CimInstance Win32_OperatingSystem
    Write-Info ("Windows: {0} (build {1})" -f $os.Caption, $os.BuildNumber)
    if ([int]$os.BuildNumber -lt 19041) {
        Fail "Windows 10 version 2004 (build 19041) ou plus recent est requis pour WSL2 / Docker Desktop."
    }

    if (Test-WslOperational) {
        Write-Info "WSL deja operationnel."
        return
    }

    $null = Test-CpuVirtualization

    if (-not (Test-IsAdmin)) {
        Request-Elevation
    }

    $needsReboot = $false

    Write-Step "Activation des composants Windows WSL + VirtualMachinePlatform"
    foreach ($name in @("Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform")) {
        $state = Get-WindowsFeatureState $name
        Write-Info "  $name : $state"
        if ($state -ne "Enabled") {
            if (Enable-WindowsFeatureCompat $name) { $needsReboot = $true }
        }
    }

    Refresh-Path
    if (Test-CommandExists "wsl") {
        $code = Install-WslWithFallbacks
        if ($code -eq 3010) { $needsReboot = $true }
        Invoke-Native -FilePath "wsl.exe" -ArgumentList @("--set-default-version", "2") -IgnoreExitCode | Out-Null
        Invoke-Native -FilePath "wsl.exe" -ArgumentList @("--update") -IgnoreExitCode | Out-Null
    } else {
        Write-Warn "wsl.exe encore introuvable — redemarrage necessaire."
        $needsReboot = $true
    }

    if ($needsReboot -or -not (Test-WslOperational)) {
        Write-Warn "WSL pas encore pret — redemarrage automatique."
        Invoke-RebootToContinue
    }

    Write-Info "WSL pret."
}

function Set-DockerDesktopDefaults {
    $dockerAppData = Join-Path $env:APPDATA "Docker"
    if (-not (Test-Path -LiteralPath $dockerAppData)) {
        New-Item -ItemType Directory -Path $dockerAppData -Force | Out-Null
    }

    $settingsJson = Join-Path $dockerAppData "settings.json"
    if (-not (Test-Path -LiteralPath $settingsJson)) {
        @{
            analyticsEnabled     = $false
            autoStart            = $true
            displayedTutorial    = $true
            wslEngineEnabled     = $true
            useWindowsContainers = $false
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $settingsJson -Encoding UTF8
        Write-Info "settings.json Docker preconfigure (WSL2)."
    }

    $storeJson = Join-Path $dockerAppData "settings-store.json"
    if (-not (Test-Path -LiteralPath $storeJson)) {
        @{
            AutoStart                   = $true
            DisplayedOnboarding         = $true
            EnableDefaultDockerSocket   = $true
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $storeJson -Encoding UTF8
    }
}

function Install-DockerViaWinget {
    if (-not (Test-CommandExists "winget")) {
        Write-Warn "winget introuvable."
        return $false
    }
    Write-Step "Installation Docker Desktop via winget"
    $code = Invoke-Native -FilePath "winget" -ArgumentList @(
        "install", "-e", "--id", "Docker.DockerDesktop",
        "--accept-package-agreements", "--accept-source-agreements",
        "--disable-interactivity", "--scope", "machine"
    ) -IgnoreExitCode
    Refresh-Path
    if (Get-DockerDesktopPath) { return $true }
    # Already installed codes vary; retry without --scope
    if ($code -ne 0) {
        $code = Invoke-Native -FilePath "winget" -ArgumentList @(
            "install", "-e", "--id", "Docker.DockerDesktop",
            "--accept-package-agreements", "--accept-source-agreements",
            "--disable-interactivity"
        ) -IgnoreExitCode
        Refresh-Path
    }
    return [bool](Get-DockerDesktopPath)
}

function Install-DockerViaDownload {
    Write-Step "Telechargement de l'installateur Docker Desktop"
    $installer = Join-Path $env:TEMP "DockerDesktopInstaller.exe"
    $urls = @(
        "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe",
        "https://desktop.docker.com/win/stable/amd64/Docker%20Desktop%20Installer.exe"
    )
    $ok = $false
    foreach ($url in $urls) {
        try {
            Write-Info "Download: $url"
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing
            if ((Test-Path -LiteralPath $installer) -and ((Get-Item $installer).Length -gt 1MB)) {
                $ok = $true
                break
            }
        } catch {
            Write-Warn "Telechargement echoue: $($_.Exception.Message)"
        }
    }
    if (-not $ok) {
        return $false
    }

    Write-Step "Installation silencieuse Docker Desktop"
    # Quiet install; may request reboot
    $code = Invoke-Native -FilePath $installer -ArgumentList @("install", "--quiet", "--accept-license", "--always-run-service") -IgnoreExitCode
    Refresh-Path
    Start-Sleep -Seconds 5
    if (Get-DockerDesktopPath) {
        Write-Info "Docker Desktop installe (download)."
        if ($code -eq 3010) {
            Write-Warn "L'installateur demande un redemarrage."
            Invoke-RebootToContinue
        }
        return $true
    }
    Write-Warn "Installateur termine (code $code) mais Docker Desktop.exe introuvable."
    return $false
}

function Install-DockerDesktop {
    Write-Step "Docker introuvable — installation automatique"
    if (-not (Test-IsAdmin)) {
        Request-Elevation
    }

    $installed = Install-DockerViaWinget
    if (-not $installed) {
        $installed = Install-DockerViaDownload
    }
    if (-not $installed) {
        Fail "Impossible d'installer Docker Desktop (winget et telechargement ont echoue). Verifiez Internet / proxy / antivirus."
    }

    Set-DockerDesktopDefaults
    Write-Info "Docker Desktop installe."
}

function Start-DockerDesktopIfNeeded {
    if (Test-DockerCli) { return }

    Set-DockerDesktopDefaults
    $desktop = Get-DockerDesktopPath
    if (-not $desktop) {
        Fail "Docker Desktop.exe introuvable apres installation."
    }

    Write-Step "Demarrage de Docker Desktop"
    try {
        Start-Process -FilePath $desktop -ArgumentList "-AcceptEula" -WorkingDirectory (Split-Path $desktop) | Out-Null
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
            Write-Info "Moteur Docker pret."
            return
        }
        $running = Get-Process -Name "Docker Desktop","com.docker.backend","com.docker.service" -ErrorAction SilentlyContinue
        if (-not $running) {
            $desktop = Get-DockerDesktopPath
            if ($desktop) {
                try { Start-Process -FilePath $desktop -ArgumentList "-AcceptEula" | Out-Null } catch { }
            }
        }
        Start-Sleep -Seconds $PollSeconds
        Write-Info "  ... Docker n'est pas encore pret"
    }
    Fail "Le moteur Docker n'est pas pret a temps. Ouvrez Docker Desktop une fois, attendez le vert, puis relancez start-atelier.bat. Journal: $LogFile"
}

function Ensure-EnvFile {
    Write-Step "Verification de .env"
    $envPath = Join-Path $Root ".env"
    $examplePath = Join-Path $Root ".env.example"
    if (-not (Test-Path -LiteralPath $envPath)) {
        if (-not (Test-Path -LiteralPath $examplePath)) {
            Fail ".env.example introuvable dans $Root"
        }
        Copy-Item -LiteralPath $examplePath -Destination $envPath
        Write-Info ".env cree depuis .env.example."
    } else {
        Write-Info ".env deja present (non ecrase)."
    }
}

function Show-PasswordHintIfNeeded {
    $logs = & docker compose logs --tail=80 init db 2>$null | Out-String
    if ($logs -match "password authentication failed for user `"odoo`"") {
        Write-Warn "Echec auth PostgreSQL: volume cree avec un ancien mot de passe."
        Write-Info "Pour repartir de zero: docker compose down -v puis relancez start-atelier.bat"
    }
}

function Wait-StackReady {
    Write-Step "Attente Odoo / module atelier_meubles (max ${StackTimeoutSec}s)"
    $deadline = (Get-Date).AddSeconds($StackTimeoutSec)

    while ((Get-Date) -lt $deadline) {
        $ps = & docker compose ps --format json 2>$null
        $initFailed = $false
        $odooUp = $false

        if ($ps) {
            foreach ($line in @($ps)) {
                if (-not $line) { continue }
                try { $row = $line | ConvertFrom-Json } catch { continue }
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

        $plain = & docker compose ps 2>$null | Out-String
        if ($plain -match "odoo\s+.*\sUp") { $odooUp = $true }
        if ($plain -match "init\s+.*Exit [1-9]") { $initFailed = $true }

        if ($initFailed) {
            & docker compose logs --tail=80 init 2>&1 | Tee-Object -Variable initLogs | Out-Host
            Write-Log ($initLogs | Out-String)
            Show-PasswordHintIfNeeded
            Fail "Le service init a echoue."
        }

        if ($odooUp) {
            $query = "SELECT state FROM ir_module_module WHERE name = 'atelier_meubles';"
            $result = & docker compose exec -T db psql -U odoo -d atelier_meubles -tAc $query 2>$null
            if ($LASTEXITCODE -eq 0 -and ($result -match "installed")) {
                Write-Info "Module atelier_meubles installe, Odoo demarre."
                return
            }
        }

        Start-Sleep -Seconds $PollSeconds
        Write-Info "  ... installation / demarrage en cours"
    }

    & docker compose ps 2>&1 | Out-Host
    & docker compose logs --tail=80 init odoo 2>&1 | Out-Host
    Show-PasswordHintIfNeeded
    Fail "Delai depasse en attendant Odoo."
}

function Invoke-SmokeTest {
    Write-Step "Execution du smoke test"
    $smokePath = Join-Path $Root "scripts\smoke_test.py"
    if (-not (Test-Path -LiteralPath $smokePath)) {
        Write-Warn "scripts\smoke_test.py introuvable — ignore."
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
    Write-Log $text

    if ($composeExit -eq 0 -and $text -match "OK: 2 meubles") {
        Write-Info "Smoke test OK."
    } else {
        Fail "Smoke test en echec ou resultat inattendu."
    }
}

# --- main ---
Ensure-LogDir
Write-Log "======== START root=$Root admin=$(Test-IsAdmin) user=$env:USERNAME ========"
Write-Host "Atelier Meubles — demarrage 100% automatique" -ForegroundColor Green
Write-Info "Journal: $LogFile"

try {
    if (Test-Path -LiteralPath $ContinueFlag) {
        Write-Info "Reprise apres redemarrage detectee."
    }

    Ensure-Wsl
    Refresh-Path

    if (-not (Get-DockerDesktopPath)) {
        Install-DockerDesktop
        Refresh-Path
    } elseif (-not (Test-CommandExists "docker") -or -not (Test-DockerCompose)) {
        # Binary missing from PATH or compose plugin broken
        if (-not (Test-CommandExists "docker")) {
            Install-DockerDesktop
            Refresh-Path
        }
    }

    Start-DockerDesktopIfNeeded
    Wait-DockerEngine

    if (-not (Test-DockerCompose)) {
        Fail "'docker compose' indisponible. Reinstallez Docker Desktop puis relancez."
    }

    Ensure-EnvFile

    Write-Step "docker compose up --build -d"
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & docker compose up --build -d 2>&1 | ForEach-Object {
        Write-Host $_
        Write-Log "$_"
    }
    $upCode = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($upCode -ne 0) {
        Show-PasswordHintIfNeeded
        Fail "Echec de docker compose up (code $upCode)."
    }

    Wait-StackReady

    Write-Step "Ouverture de $OdooUrl"
    Start-Process $OdooUrl
    Write-Info "Connexion initiale : admin / admin"

    Invoke-SmokeTest
    Clear-ContinueAfterReboot

    Write-Host ""
    Write-Info "Pret. Odoo : $OdooUrl  (admin / admin)"
    Write-Log "======== SUCCESS ========"
    exit 0
}
catch {
    Write-Log ($_ | Out-String) "ERROR"
    Fail ("Exception: " + $_.Exception.Message)
}
