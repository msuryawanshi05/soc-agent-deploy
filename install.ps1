# Run as Administrator
Write-Host "Installing SOC Agent (Windows)..." -ForegroundColor Cyan

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host "Python not found! Please install Python 3.8+ from https://python.org" -ForegroundColor Red
    exit 1
}

Write-Host "Installing dependencies..." -ForegroundColor Yellow
pip install -r requirements.txt

if (-not (Test-Path ".env")) {
    Copy-Item ".env.example" ".env"
    Write-Host "Created .env - MANAGER_HOST is pre-set to 168.144.73.18" -ForegroundColor Green
}

# Register as scheduled task for persistence
$action   = New-ScheduledTaskAction -Execute "python" -Argument "$PSScriptRoot\agent\agent.py" -WorkingDirectory $PSScriptRoot
$trigger  = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName "SOC-Agent" -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest -Force

Write-Host "Done! Agent is registered to start on boot." -ForegroundColor Green
Write-Host "To start now, run: python agent\agent.py" -ForegroundColor White
