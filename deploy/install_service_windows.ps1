#Requires -RunAsAdministrator
# ============================================================
#  SOC Agent — Windows Service Installer (Protected Install)
#  Must be run as Administrator in PowerShell
#
#  Usage:
#    .\install_service_windows.ps1 <MANAGER_IP> <AGENT_NUM> <MACHINE_NAME>
#    .\install_service_windows.ps1 -Uninstall
#
#  Installs to: C:\ProgramData\SocAgent\  (hidden, system, SYSTEM+Admins only)
# ============================================================

param(
    [string]$ManagerIp   = "",
    [string]$AgentNum    = "",
    [string]$MachineName = "",
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$SERVICE_NAME  = "SOCAgent"
$INSTALL_DIR   = "C:\ProgramData\SocAgent"
$REPO_URL      = "https://github.com/msuryawanshi05/soc-agent-deploy.git"

# ── Helper: locate Python ──────────────────────────────────────────────────────
function Find-Python {
    foreach ($cmd in @("python", "python3")) {
        $p = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($p) { return $p.Source }
    }
    $globs = @(
        "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe",
        "$env:ProgramFiles\Python3*\python.exe",
        "C:\Python3*\python.exe"
    )
    foreach ($g in $globs) {
        $m = Get-ChildItem $g -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if ($m) { return $m.FullName }
    }
    return $null
}

# ── Helper: locate Git ────────────────────────────────────────────────────────
function Find-Git {
    $g = Get-Command git -ErrorAction SilentlyContinue
    if ($g) { return $g.Source }
    foreach ($p in @("C:\Program Files\Git\cmd\git.exe","C:\Program Files (x86)\Git\cmd\git.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

# ── UNINSTALL ─────────────────────────────────────────────────────────────────
if ($Uninstall) {
    Write-Host "`n[Uninstall] Removing SOC Agent..." -ForegroundColor Yellow
    $svc = Get-Service -Name $SERVICE_NAME -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.Status -eq "Running") { Stop-Service $SERVICE_NAME -Force }
        $python = Find-Python
        $svcScript = Join-Path $INSTALL_DIR "agent\agent_service.py"
        if ($python -and (Test-Path $svcScript)) {
            & $python $svcScript remove 2>$null
        } else {
            sc.exe delete $SERVICE_NAME | Out-Null
        }
        Write-Host "  Service removed." -ForegroundColor Green
    }
    # Remove install dir (need to strip protection first)
    if (Test-Path $INSTALL_DIR) {
        attrib -h -s $INSTALL_DIR
        $acl = Get-Acl $INSTALL_DIR
        $acl.SetAccessRuleProtection($false, $true)
        Set-Acl $INSTALL_DIR $acl
        Remove-Item -Recurse -Force $INSTALL_DIR
        Write-Host "  Install directory removed." -ForegroundColor Green
    }
    Write-Host "✅ SOC Agent fully removed." -ForegroundColor Green
    exit 0
}

# ── Argument check ────────────────────────────────────────────────────────────
if (-not $ManagerIp -or -not $AgentNum -or -not $MachineName) {
    Write-Host "Usage: .\install_service_windows.ps1 <MANAGER_IP> <AGENT_NUM> <MACHINE_NAME>"
    Write-Host "       .\install_service_windows.ps1 -Uninstall"
    Write-Host "Example: .\install_service_windows.ps1 192.168.1.100 5 lab-pc-5"
    exit 1
}
$AGENT_ID = "agent-" + $AgentNum.PadLeft(3, '0')

Write-Host "`n═══════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  SOC Agent — Windows Protected Installer"   -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════`n" -ForegroundColor Cyan

# ── Step 1: Locate Python ─────────────────────────────────────────────────────
Write-Host "[1/7] Locating Python..." -ForegroundColor Yellow
$python = Find-Python
if (-not $python) {
    Write-Host "ERROR: Python 3.8+ required. Install from https://python.org" -ForegroundColor Red; exit 1
}
Write-Host "      $python" -ForegroundColor Green

# ── Step 2: Locate / install Git ─────────────────────────────────────────────
Write-Host "[2/7] Locating Git..." -ForegroundColor Yellow
$git = Find-Git
if (-not $git) {
    Write-Host "      Git not found. Installing via winget..." -ForegroundColor Yellow
    winget install --id Git.Git -e --source winget --silent 2>$null
    $git = Find-Git
    if (-not $git) {
        Write-Host "ERROR: Git install failed. Install manually from https://git-scm.com" -ForegroundColor Red; exit 1
    }
}
Write-Host "      $git" -ForegroundColor Green

# ── Step 3: Clone / update install directory ──────────────────────────────────
Write-Host "[3/7] Setting up install directory ($INSTALL_DIR)..." -ForegroundColor Yellow
if (Test-Path "$INSTALL_DIR\.git") {
    # Already cloned — pull latest
    attrib -h -s $INSTALL_DIR 2>$null
    & $git -C $INSTALL_DIR fetch origin --quiet
    & $git -C $INSTALL_DIR reset --hard origin/main --quiet
    Write-Host "      Repository updated." -ForegroundColor Green
} else {
    if (Test-Path $INSTALL_DIR) { Remove-Item -Recurse -Force $INSTALL_DIR }
    & $git clone $REPO_URL $INSTALL_DIR --quiet
    Write-Host "      Repository cloned." -ForegroundColor Green
}

# ── Step 4: Write .env ───────────────────────────────────────────────────────
Write-Host "[4/7] Writing .env configuration..." -ForegroundColor Yellow
$envContent = @"
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
"@
Set-Content -Path "$INSTALL_DIR\.env" -Value $envContent -Encoding UTF8
Write-Host "      .env written." -ForegroundColor Green

# ── Step 5: Install pip deps + compile .py → .pyc ────────────────────────────
Write-Host "[5/7] Installing dependencies and compiling to .pyc..." -ForegroundColor Yellow
& $python -m pip install -r "$INSTALL_DIR\requirements.txt" --quiet
& $python -m compileall $INSTALL_DIR -q
Write-Host "      Dependencies installed and .pyc compiled." -ForegroundColor Green

# ── Step 6: Lock down permissions ─────────────────────────────────────────────
Write-Host "[6/7] Applying access restrictions..." -ForegroundColor Yellow

# Hidden + System attributes (hides from Explorer)
attrib +h +s $INSTALL_DIR

# ACL: remove all inheritance, grant SYSTEM full, grant Administrators full, remove Everyone/Users
$acl = Get-Acl $INSTALL_DIR
$acl.SetAccessRuleProtection($true, $false)  # block inheritance, remove inherited rules
$acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }

$systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "SYSTEM", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
$adminRule  = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "Administrators", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")

$acl.AddAccessRule($systemRule)
$acl.AddAccessRule($adminRule)
Set-Acl $INSTALL_DIR $acl
Write-Host "      Folder: hidden + system. Access: SYSTEM + Administrators only." -ForegroundColor Green

# ── Step 7: Register Windows Service ──────────────────────────────────────────
Write-Host "[7/7] Registering Windows Service '$SERVICE_NAME'..." -ForegroundColor Yellow

# Ensure pywin32
& $python -c "import win32serviceutil" 2>$null
if ($LASTEXITCODE -ne 0) {
    & $python -m pip install pywin32 --quiet
    $post = Join-Path (Split-Path $python) "Scripts\pywin32_postinstall.py"
    if (Test-Path $post) { & $python $post -install 2>$null }
}

$svcScript = "$INSTALL_DIR\agent\agent_service.py"
$existing = Get-Service -Name $SERVICE_NAME -ErrorAction SilentlyContinue
if ($existing) {
    if ($existing.Status -eq "Running") { Stop-Service $SERVICE_NAME -Force }
    & $python $svcScript remove 2>$null
    Start-Sleep -Seconds 1
}

& $python $svcScript install
sc.exe config  $SERVICE_NAME start= auto | Out-Null
sc.exe description $SERVICE_NAME "SOC Platform Monitoring Agent" | Out-Null
# Auto-restart on failure: restart after 5s, 3 attempts
sc.exe failure $SERVICE_NAME reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
Start-Service $SERVICE_NAME
Start-Sleep -Seconds 2

# ── Verify ────────────────────────────────────────────────────────────────────
Write-Host "`n=== Verification ===" -ForegroundColor Cyan
sc.exe query $SERVICE_NAME
$svc = Get-Service -Name $SERVICE_NAME -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") {
    Write-Host "`n✅ SOC Agent: RUNNING | Path: $INSTALL_DIR | Auto-start: ON" -ForegroundColor Green
} else {
    Write-Host "`n⚠️  Service installed but not running. Check Event Viewer." -ForegroundColor Yellow
}
Write-Host "`nCommands:"
Write-Host "  sc query $SERVICE_NAME"
Write-Host "  Stop-Service $SERVICE_NAME   (Admin only)"
Write-Host "  .\install_service_windows.ps1 -Uninstall"
