# Destructive only to a NEW test installation on a disposable GitHub-hosted runner.
# This is not interactive desktop/UAC/SmartScreen or physical driver acceptance.
param([Parameter(Mandatory=$true)][string]$Setup)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Fresh install test requires a disposable GitHub-hosted runner'
}
$root = Join-Path $env:LOCALAPPDATA 'Couchside'
$data = Join-Path $env:ProgramData 'Couchside'
if ((Test-Path $root) -or (Test-Path $data) -or (Get-ScheduledTask -TaskName 'Couchside Agent' -ErrorAction SilentlyContinue)) {
    throw 'Existing Couchside footprint; refusing to modify it'
}
$setupPath = (Resolve-Path $Setup).Path
$fixture = Join-Path $env:RUNNER_TEMP ('couchside-install-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $fixture | Out-Null
function Run-Setup([string]$Exe, [string]$Arguments) {
    $p = Start-Process -FilePath $Exe -ArgumentList $Arguments -PassThru
    $null = $p.Handle
    if (-not $p.WaitForExit(240000)) {
        & taskkill.exe /PID $p.Id /T /F | Out-Null
        throw 'Installer exceeded four minutes'
    }
    if ($p.ExitCode -ne 0) { throw "Installer failed with exit code $($p.ExitCode)" }
}
function Check-Installation {
    $installed = Join-Path $root 'agent\couchside-agent.exe'
    if ((Get-FileHash $installed).Hash -ne (Get-FileHash 'dist/couchside-agent.exe').Hash) { throw 'Installed agent differs from build' }
    $task = Get-ScheduledTask -TaskName 'Couchside Agent'
    if ($task.Principal.RunLevel -ne 'Limited' -or $task.Principal.LogonType -ne 'Interactive') { throw 'Unexpected startup privileges' }
    if ($task.Actions.Execute -ne $installed) { throw 'Startup task does not use packaged EXE' }
    if (Test-Path (Join-Path $root 'agent\couchsided-win.py')) { throw 'Unexpected source/Python install' }
    $dll = Join-Path $root 'agent\ViGEmClient.dll'
    if ((Get-FileHash $dll).Hash -ne '2BF0CB1D809039573C922737D298A1653D4DBC61408060FF45A9BCFDE82E97D2') { throw 'Downloaded controller DLL mismatch' }
}
try {
    Run-Setup $setupPath ('/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /LOG="' + $fixture + '\fresh.log"')
    Check-Installation
    $configPath = Join-Path $data 'config.json'
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    if ($config.allow_update_check -or $config.allow_app_update) { throw 'Fresh install enabled updates without consent' }
    $tokenHash = (Get-FileHash (Join-Path $data 'token')).Hash
    # Opt in locally, then prove a silent upgrade preserves consent and unknown data.
    $config | Add-Member -Force NoteProperty allow_update_check $true
    $config | Add-Member -Force NoteProperty qa_preserve 'synthetic-install-fixture'
    [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 10))
    $configHash = (Get-FileHash $configPath).Hash
    Run-Setup $setupPath ('/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /LOG="' + $fixture + '\upgrade.log"')
    Check-Installation
    if ((Get-FileHash (Join-Path $data 'token')).Hash -ne $tokenHash) { throw 'Upgrade replaced pairing token' }
    if ((Get-FileHash $configPath).Hash -ne $configHash) { throw 'Upgrade changed settings or consent' }
    Write-Host 'PASS: fresh packaged install, default-off updates, Limited/Interactive task, verified DLL, silent upgrade preserves token/config/consent.'
    $driver = [bool](Get-Service -Name ViGEmBus -ErrorAction SilentlyContinue)
    Write-Host "ViGEmBus present on runner: $driver (not a physical gamepad acceptance test)."
} finally {
    # Preflight proved these locations did not exist before this test.
    $uninstall = Join-Path $root 'bootstrap\unins000.exe'
    if (Test-Path $uninstall) {
        Run-Setup $uninstall '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
        if (Get-ScheduledTask -TaskName 'Couchside Agent' -ErrorAction SilentlyContinue) { throw 'Uninstall left startup task' }
        if (Test-Path (Join-Path $root 'agent\couchside-agent.exe')) { throw 'Uninstall left agent executable' }
        Write-Host 'PASS: uninstaller removed agent and startup task.'
    }
}
