#Requires -RunAsAdministrator
param([switch]$Uninstall)

$ErrorActionPreference = "Stop"
$SERVICE_NAME = "WinSvcHelper"
$INSTALL_DIR  = "C:\ProgramData\SocAgent"
$LOG_FILE     = "$INSTALL_DIR\install.log"
$MIN_DISK_MB  = 200
$SOURCE_ROOT  = Split-Path -Parent $PSScriptRoot
$ROLLED_BACK  = $false

function log {
    param([string]$Msg, [string]$Color = "White")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $Msg"
    Write-Host $line -ForegroundColor $Color
    if (Test-Path $INSTALL_DIR) {
        try { Add-Content -Path $LOG_FILE -Value $line -ErrorAction SilentlyContinue } catch {}
    }
}

function Invoke-Rollback {
    if ($script:ROLLED_BACK) { return }
    $script:ROLLED_BACK = $true
    log "ERROR: Installation failed - rolling back..." "Red"
    try {
        $svc = Get-Service $SERVICE_NAME -ErrorAction SilentlyContinue
        if ($svc) {
            if ($svc.Status -eq "Running") { Stop-Service $SERVICE_NAME -Force -ErrorAction SilentlyContinue }
            $py = Find-Python
            $ss = "$INSTALL_DIR\agent\agent_service.py"
            if ($py -and (Test-Path $ss)) { & $py $ss remove 2>$null }
            else { sc.exe delete $SERVICE_NAME 2>$null | Out-Null }
        }
    } catch {}
    try {
        if (Test-Path $INSTALL_DIR) {
            icacls $INSTALL_DIR /remove:d "Everyone" /T /C /Q | Out-Null
            icacls $INSTALL_DIR /reset /T /C /Q | Out-Null
            attrib -h -s $INSTALL_DIR /S /D 2>$null | Out-Null
            Remove-Item -Recurse -Force $INSTALL_DIR -ErrorAction SilentlyContinue
        }
    } catch {}
    log "Rollback complete." "Yellow"
}

function Find-Python {
    foreach ($cmd in @("python","python3")) {
        $p = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($p) { return $p.Source }
    }
    foreach ($g in @(
        "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe",
        "$env:ProgramFiles\Python3*\python.exe",
        "C:\Python3*\python.exe"
    )) {
        $m = Get-ChildItem $g -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if ($m) { return $m.FullName }
    }
    return $null
}

function Find-Pythonw {
    $py = Find-Python
    if (-not $py) { return $null }
    $pythonw = Join-Path (Split-Path $py) "pythonw.exe"
    if (Test-Path $pythonw) { return $pythonw }
    return $py
}

if ($Uninstall) {
    New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null
    log "=== SOC Agent Uninstall ===" "Yellow"
    $svc = Get-Service $SERVICE_NAME -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.Status -eq "Running") { Stop-Service $SERVICE_NAME -Force }
        $py = Find-Python
        $ss = "$INSTALL_DIR\agent\agent_service.py"
        if ($py -and (Test-Path $ss)) { & $py $ss remove 2>$null }
        else { sc.exe delete $SERVICE_NAME | Out-Null }
        log "Service removed." "Green"
    }
    if (Test-Path $INSTALL_DIR) {
        icacls $INSTALL_DIR /remove:d "Everyone" /T /C /Q | Out-Null
        icacls $INSTALL_DIR /reset /T /C /Q | Out-Null
        attrib -h -s $INSTALL_DIR /S /D 2>$null | Out-Null
        Remove-MpPreference -ExclusionPath $INSTALL_DIR -ErrorAction SilentlyContinue
        $pythonw = Find-Pythonw
        if ($pythonw) { Remove-MpPreference -ExclusionProcess $pythonw -ErrorAction SilentlyContinue }
        Remove-Item -Recurse -Force $INSTALL_DIR
        log "Install directory removed." "Green"
    }
    log "SOC Agent fully uninstalled." "Green"
    exit 0
}

Write-Host ""
Write-Host "  SOC Agent - Windows Installer" -ForegroundColor Cyan
Write-Host ""

$AGENT_ID = ""
while ([string]::IsNullOrWhiteSpace($AGENT_ID)) {
    $AGENT_ID = (Read-Host "Enter Agent ID (e.g. agent-lab-01)").Trim()
}

$SYS_HOSTNAME = $env:COMPUTERNAME
$HostnameInput = (Read-Host "Enter Agent Hostname [$SYS_HOSTNAME]").Trim()
$MachineName = if ([string]::IsNullOrWhiteSpace($HostnameInput)) { $SYS_HOSTNAME } else { $HostnameInput }

$IPInput = (Read-Host "Enter Manager IP [139.59.48.159]").Trim()
$ManagerIp = if ([string]::IsNullOrWhiteSpace($IPInput)) { "139.59.48.159" } else { $IPInput }
$MANAGER_PORT = 9000

Write-Host ""
Write-Host " Agent ID     : $AGENT_ID"
Write-Host " Hostname     : $MachineName"
Write-Host " Manager IP   : $ManagerIp"
Write-Host " Manager Port : $MANAGER_PORT"
Write-Host ""

$confirm = (Read-Host "Proceed with installation? [Y/n]").Trim()
if ($confirm -eq 'n' -or $confirm -eq 'N') {
    Write-Host "Installation aborted." -ForegroundColor Yellow
    exit 0
}

New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null

try {
    log "[1/10] Checking disk space..."
    $drv = (Split-Path -Qualifier $INSTALL_DIR) -replace ':',''
    $disk = Get-PSDrive $drv -ErrorAction SilentlyContinue
    if ($disk) {
        $freeMB = [math]::Round($disk.Free / 1MB)
        if ($freeMB -lt $MIN_DISK_MB) { throw "Insufficient disk space: need ${MIN_DISK_MB}MB, have ${freeMB}MB." }
        log "    Free space: ${freeMB}MB OK" "Green"
    }

    log "[2/10] Checking existing installation..."
    $existSvc = Get-Service $SERVICE_NAME -ErrorAction SilentlyContinue
    $existDir = Test-Path "$INSTALL_DIR\agent\agent.py"
    if ($existSvc -or $existDir) {
        $r = Read-Host "    SOC Agent already installed. Reinstall? [y/N]"
        if ($r -notin @('y','Y')) { log "Skipping - existing install kept." "Yellow"; exit 0 }
        log "    Proceeding with reinstall..." "Yellow"
        if ($existSvc -and $existSvc.Status -eq "Running") { Stop-Service $SERVICE_NAME -Force -ErrorAction SilentlyContinue }
    } else {
        log "    No existing installation." "Green"
    }

    log "[3/10] Checking Python..."
    $python = Find-Python
    if (-not $python) {
        log "    Python not found - installing via winget..." "Yellow"
        winget install --id Python.Python.3.12 -e --source winget --silent --accept-package-agreements --accept-source-agreements 2>$null
        $machinePath = [System.Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::Machine)
        $userPath = [System.Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::User)
        $env:PATH = "$machinePath;$userPath"
        $python = Find-Python
        if (-not $python) { throw "Python install via winget failed." }
    }
    log "    Python: $python" "Green"

    log "[4/10] Copying agent files..."
    foreach ($folder in @("agent","shared","database")) {
        $src = Join-Path $SOURCE_ROOT $folder
        if (Test-Path $src) { Copy-Item -Path $src -Destination $INSTALL_DIR -Recurse -Force }
    }
    $src = Join-Path $SOURCE_ROOT "requirements.txt"
    if (Test-Path $src) { Copy-Item $src $INSTALL_DIR -Force }

    $envLines = @(
        "MANAGER_HOST=$ManagerIp",
        "MANAGER_PORT=9000",
        "AGENT_ID=$AGENT_ID",
        "AGENT_HOSTNAME=$MachineName",
        "AGENT_SEND_INTERVAL=1",
        "MONITOR_BROWSER_HISTORY=true",
        "MONITOR_ACTIVE_WINDOW=true",
        "MONITOR_USB_DEVICES=true",
        "MONITOR_SHELL_COMMANDS=true",
        "MONITOR_PROCESSES=true"
    )
    $envLines | Set-Content "$INSTALL_DIR\.env" -Encoding UTF8
    log "    Wrote .env" "Green"

    log "[5/10] Installing dependencies..."
    & $python -m pip install -r "$INSTALL_DIR\requirements.txt" --quiet
    if ($LASTEXITCODE -ne 0) { throw "pip install failed." }
    & $python -m compileall $INSTALL_DIR -q
    log "    Dependencies installed." "Green"

    log "[6/10] Applying protection..."
    attrib +h +s $INSTALL_DIR
    $acl = Get-Acl $INSTALL_DIR
    $acl.SetAccessRuleProtection($true, $false)
    $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("SYSTEM","FullControl","ContainerInherit,ObjectInherit","None","Allow")))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators","FullControl","ContainerInherit,ObjectInherit","None","Allow")))
    Set-Acl $INSTALL_DIR $acl
    takeown /F $INSTALL_DIR /R /A /D Y 2>&1 | Out-Null
    icacls $INSTALL_DIR /setowner "SYSTEM" /T /C /Q | Out-Null
    icacls $INSTALL_DIR /deny "Everyone:(D,DC)" /T /C /Q | Out-Null
    Add-MpPreference -ExclusionPath $INSTALL_DIR -ErrorAction SilentlyContinue
    $pythonw = Find-Pythonw
    if ($pythonw) { Add-MpPreference -ExclusionProcess $pythonw -ErrorAction SilentlyContinue }
    log "    Protection applied." "Green"

    log "[7/10] Registering service..."
    if (-not $pythonw) { throw "pythonw.exe not found." }
    & $pythonw -c "import win32serviceutil" 2>$null
    if ($LASTEXITCODE -ne 0) {
        & $pythonw -m pip install pywin32 --quiet
        $post = Join-Path (Split-Path $pythonw) "Scripts\pywin32_postinstall.py"
        if (Test-Path $post) { & $pythonw $post -install 2>$null }
    }
    $svcScript = "$INSTALL_DIR\agent\agent_service.py"
    $old = Get-Service $SERVICE_NAME -ErrorAction SilentlyContinue
    if ($old) {
        if ($old.Status -eq "Running") { Stop-Service $SERVICE_NAME -Force }
        & $pythonw $svcScript remove 2>$null
    }
    & $pythonw $svcScript install
    if ($LASTEXITCODE -ne 0) { throw "Service install failed." }
    sc.exe config $SERVICE_NAME start= auto | Out-Null
    sc.exe description $SERVICE_NAME "Windows System Helper" | Out-Null
    sc.exe failure $SERVICE_NAME reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
    Start-Service $SERVICE_NAME
    log "    Service registered and started." "Green"

    log "[8/10] Checking manager reachability..."
    $conn = Test-NetConnection -ComputerName $ManagerIp -Port 9000 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    if ($conn.TcpTestSucceeded) { log "    Manager reachable OK" "Green" } else { log "    WARNING: Manager unreachable - check IP after install" "Yellow" }

    log "[9/10] Verifying service..."
    Start-Sleep -Seconds 2
    $svc = Get-Service $SERVICE_NAME -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        log "    Service running OK" "Green"
    } else {
        throw "Service failed to start."
    }

    log "[10/10] Done."
    Write-Host ""
    Write-Host "SOC Agent installed successfully!" -ForegroundColor Green
    Write-Host "Service : $SERVICE_NAME" -ForegroundColor Green
    Write-Host "Path    : $INSTALL_DIR" -ForegroundColor Green

} catch {
    log "FATAL: $_" "Red"
    Invoke-Rollback
    exit 1
}
