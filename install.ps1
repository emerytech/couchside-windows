# Couchside Windows agent installer.
#
# ONE-LINE INSTALL (run in PowerShell; it self-elevates via UAC):
#
#   irm https://couchside.tv/install.ps1 | iex
#
# With options (download the script so params survive the pipe):
#
#   irm https://couchside.tv/install.ps1 -OutFile install.ps1
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Port 9000 -NoGamepad
#
# Uninstall:
#
#   irm https://couchside.tv/install.ps1 -OutFile install.ps1
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
#
# What it does (all reversible with -Uninstall):
#   1. installs Python 3 (via winget) if it isn't already present
#   2. downloads the agent to %LOCALAPPDATA%\Couchside\agent\ (or copies it
#      from a repo checkout when this script sits next to agent\win\)
#   3. installs the ViGEmBus driver + client DLL for the virtual gamepad
#      (skip with -NoGamepad)
#   4. creates %ProgramData%\Couchside\token (pairing secret) + config.json
#   5. opens TCP 8787 inbound for the network profile(s) this box is on
#      (Private, plus Public/Domain when the active network is classed that way,
#      so a home LAN Windows misclassifies as "Public" still pairs)
#   6. registers a Scheduled Task that starts the agent at logon, in the
#      interactive desktop session, NON-elevated (virtual input can't reach
#      the desktop from a session-0 service; unprivileged mirrors the Linux
#      agent's least-privilege model - its LAN-facing action/launcher API
#      must never run as admin)
#   7. installs a taskbar tray widget (Startup shortcut) - a Decky-style panel
#      to start/stop/restart the agent, show the pairing QR, and toggle
#      start-at-logon (Python installs only; the prebuilt-exe path has no
#      interpreter for the .pyw GUI)
#   8. opens http://localhost:8787/pair so you can scan the QR to pair

[CmdletBinding()]
param(
    [switch]$Uninstall,
    [int]$Port = 8787,
    [switch]$NoFirewall,
    [switch]$NoGamepad,      # skip the ViGEmBus virtual-controller install
    [switch]$KeepHibernate,  # skip `powercfg /hibernate off`
    [switch]$Elevated,       # run the agent task ELEVATED (admin). OPT-IN: lets the
                             # phone's mouse/keyboard drive ADMIN app windows (Windows
                             # UIPI blocks a non-elevated agent from injecting into a
                             # higher-integrity foreground window). Tradeoff: a LAN
                             # token holder can then drive admin app windows with the
                             # virtual input (the command allowlist still holds - no
                             # arbitrary shell). Default OFF (least privilege).
    [switch]$NoElevated,     # explicitly non-elevated; suppresses the interactive
                             # prompt (for scripted/unattended installs)
    [string]$Ref = 'main',   # git ref to download the agent from
    [switch]$FromInstaller   # set by CouchsideSetup.exe: the elevated relaunch must
                             # WAIT (so the installer's Exec() tracks the real
                             # install) and must NOT keep a -NoExit window open
)

$ErrorActionPreference = 'Stop'
# GitHub requires TLS 1.2; Windows PowerShell 5.1 may default lower.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$SelfUrl    = 'https://couchside.tv/install.ps1'
$Repo       = 'emerytech/couchside'
$RawBase    = "https://raw.githubusercontent.com/$Repo/$Ref/agent"
# Default: fetch a PINNED, MAINTAINER-SIGNED agent from the latest GitHub release
# (Ed25519-signed SHA256SUMS), NOT mutable main. `-Ref <branch>` opts into the old
# raw-main download for development, which is unverified (a printed warning says so).
$ReleaseBase = "https://github.com/$Repo/releases/latest/download"
$UseRelease  = -not $PSBoundParameters.ContainsKey('Ref')
# Ed25519 public keys the release SHA256SUMS is signed with (primary + rollover
# backup); kept byte-identical to install.sh's RELEASE_PUBKEY_PEM.
$ReleasePubKeys = @(
    "-----BEGIN PUBLIC KEY-----`nMCowBQYDK2VwAyEA+9aBnheHC7N3J9JNfkP2PoBf89SCkBxmqlZ/2lrcwGA=`n-----END PUBLIC KEY-----",
    "-----BEGIN PUBLIC KEY-----`nMCowBQYDK2VwAyEAtW4oYkhFGiWZ8nM8u3ldwecPekFQHdabdTI807VoUmE=`n-----END PUBLIC KEY-----"
)
$TaskName   = 'Couchside Agent'
$InstallDir = Join-Path $env:LOCALAPPDATA 'Couchside\agent'
$DataDir    = Join-Path $env:ProgramData 'Couchside'
$TokenPath  = Join-Path $DataDir 'token'
$ConfigPath = Join-Path $DataDir 'config.json'
$FwRule     = 'Couchside Agent'
$TrayName   = 'Couchside Tray'
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Couchside Tray.lnk'
# BEGIN installer port helpers
function Resolve-InstallerPort {
    param([int]$RequestedPort, [bool]$ExplicitPort, [string]$Path)
    $effective = $RequestedPort
    if (-not $ExplicitPort -and (Test-Path $Path)) {
        $saved = $null
        try { $saved = (Get-Content $Path -Raw | ConvertFrom-Json).port } catch { }
        if ($null -ne $saved) {
            if ($saved -isnot [int] -and $saved -isnot [long]) { throw 'Saved agent port must be an integer from 1 through 65534.' }
            $effective = $saved
        }
    }
    if ($effective -lt 1 -or $effective -gt 65534) { throw 'Agent port must be from 1 through 65534 (HTTP plus HTTPS).' }
    return [int]$effective
}

function Save-ExplicitInstallerPort {
    param([int]$RequestedPort, [string]$Path)
    $effective = Resolve-InstallerPort -RequestedPort $RequestedPort -ExplicitPort $true -Path $Path
    # Read the latest config after stopping the agent; preserve every other field.
    $saved = Get-Content $Path -Raw | ConvertFrom-Json
    if ($saved.port -ne $effective) {
        $saved | Add-Member -MemberType NoteProperty -Name port -Value $effective -Force
        [IO.File]::WriteAllText($Path, ($saved | ConvertTo-Json -Depth 100) + "`n")
        Write-Host "Updated configured port to $effective. Other settings retained."
    }
}
# END installer port helpers
$PortWasSpecified = $PSBoundParameters.ContainsKey('Port')
if (-not $Uninstall) { $Port = Resolve-InstallerPort -RequestedPort $Port -ExplicitPort $PortWasSpecified -Path $ConfigPath }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- self-elevate (works whether run from a file OR piped via irm|iex) -------
# The firewall rule + scheduled task need admin, so relaunch under UAC. The
# elevated instance keeps the SAME user (UAC elevation doesn't switch users),
# so the logon task still targets the person installing.
if (-not (Test-Admin)) {
    Write-Host 'Couchside needs administrator rights (firewall + scheduled task). Elevating via UAC...'
    $fwd = @()
    if ($Uninstall)      { $fwd += '-Uninstall' }
    if ($NoFirewall)     { $fwd += '-NoFirewall' }
    if ($NoGamepad)      { $fwd += '-NoGamepad' }
    if ($KeepHibernate)  { $fwd += '-KeepHibernate' }
    if ($Elevated)       { $fwd += '-Elevated' }
    if ($NoElevated)     { $fwd += '-NoElevated' }
    if ($FromInstaller)  { $fwd += '-FromInstaller' }
    if ($PortWasSpecified) { $fwd += "-Port $Port" }
    if ($PSBoundParameters.ContainsKey('Ref')) { $fwd += "-Ref $Ref" }
    # A human running this directly wants -NoExit so the elevated window stays up to
    # read. The Inno installer wants the opposite: no leftover window, AND the outer
    # (non-elevated) process must block on the elevated child so its Exec() sees real
    # completion instead of the async RunAs handoff returning instantly.
    #
    # -WindowStyle Hidden matters more than it looks: CouchsideSetup.exe runs THIS
    # script hidden, but -Verb RunAs spawns a brand-new console that inherits none of
    # that, so an install driven by the wizard still threw a full PowerShell window
    # (and everything winget prints into it) across the user's screen for the whole
    # install. The wizard already shows its own progress; the elevated half should be
    # invisible. A human running install.ps1 by hand still gets the visible window.
    $base = @('-NoProfile','-ExecutionPolicy','Bypass')
    if ($FromInstaller) { $base += @('-WindowStyle','Hidden') } else { $base += '-NoExit' }
    if ($PSCommandPath) {
        # Run from a file: relaunch that same file elevated.
        $a = $base + @('-File',"`"$PSCommandPath`"") + $fwd
    } else {
        # Piped from the web: re-fetch and run in the elevated window, carrying
        # the resolved params through a scriptblock so options aren't lost.
        $inner = "& ([scriptblock]::Create((irm $SelfUrl))) $($fwd -join ' ')"
        $a = $base + @('-Command',$inner)
    }
    try {
        if ($FromInstaller) {
            # -Wait blocks the outer process so the caller sees the install finish
            # rather than the async RunAs handoff returning instantly; -PassThru
            # lets us mirror the child's exit code outward.
            # This exit code is LOAD-BEARING as of couchside-windows 896d4be:
            # CouchsideSetup.exe runs this script from Inno's PrepareToInstall and
            # aborts the wizard (exit code 7, error on screen, nothing installed)
            # when it is non-zero. Before that it ran from a [Run] entry, which
            # never inspects exit codes -- a failed install still showed "Setup
            # completed successfully". So do not swallow a failure here.
            # Start-Process -Wait includes every descendant, including the
            # pairing browser. Wait on the actual installer process instead.
            $child = Start-Process powershell -Verb RunAs -ArgumentList $a -PassThru
            $null = $child.Handle # retain a handle even if the elevated child exits immediately
            $child.WaitForExit()
            $childExit = $child.ExitCode
            if ($null -eq $childExit) { throw 'Elevated installer did not provide an exit code; refusing to report success.' }
            exit $childExit
            # END elevated installer wait
        }
        Start-Process powershell -Verb RunAs -ArgumentList $a
    }
    catch { throw "Could not complete elevated installation: $_ Re-run from an elevated PowerShell if necessary." }
    return
}

# --- shared helpers ----------------------------------------------------------
# BEGIN firewall helpers
function Invoke-InstallerWorker {
    param([string]$Code, [string]$Label, [int]$TimeoutSeconds = 45)
    # A separate process bounds COM/CIM provider hangs. No shell, script file,
    # profile, network download, or external child process is used by this worker.
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $Code = '[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);' + $Code
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code))
    $info.Arguments = "-NoProfile -NonInteractive -EncodedCommand $encoded"
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw "$Label could not start." }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            if (-not $process.WaitForExit(5000)) { throw "$Label timed out and its worker could not be stopped." }
            throw "$Label timed out after $TimeoutSeconds seconds. Check Windows Firewall and retry."
        }
        $output = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "$Label failed (exit $($process.ExitCode)): $errorText" }
        if ($output.Trim()) { Write-Host $output.Trim() }
    } finally {
        $process.Dispose()
    }
}

function Set-CouchsideFirewall {
    param([switch]$RemoveOnly)
    if ($NoFirewall -and -not $RemoveOnly) { return }
    $agentProgram = if ($usePython) { $pyPath } else { Join-Path $InstallDir 'couchside-agent.exe' }
    # Base64 JSON transports values as data, never interpolated PowerShell code.
    $data = @{port=$Port; program=$agentProgram; removeOnly=[bool]$RemoveOnly} | ConvertTo-Json -Compress
    $data64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($data))
    $worker = @'
$ErrorActionPreference = 'Stop'
try {
    $settings = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__SETTINGS__')) | ConvertFrom-Json
    $Port = [int]$settings.port
    if (-not $settings.removeOnly -and ($Port -lt 1 -or $Port -gt 65534)) { throw 'Agent port must be between 1 and 65534 for HTTP + HTTPS.' }
    $policy = New-Object -ComObject HNetCfg.FwPolicy2
    # The NetSecurity CIM bulk-delete path can stall on legacy duplicate rules.
    # Use Windows' Firewall COM collection instead, matching only our exact names.
    foreach ($name in @('Couchside Agent','Couchside Agent HTTPS','Couchside Agent Discovery')) {
        $remaining = @($policy.Rules | Where-Object { $_.Name -eq $name }).Count
        $maxAttempts = $remaining
        $attempts = 0
        while ($remaining -gt 0) {
            if ($attempts -ge $maxAttempts) { throw "Removal limit reached for firewall rule '$name'. Check Group Policy or concurrent policy changes." }
            $attempts++
            try { $policy.Rules.Remove($name) }
            catch { throw "Cannot remove firewall rule '$name'. Check permissions or Group Policy: $_" }
            $after = @($policy.Rules | Where-Object { $_.Name -eq $name }).Count
            if ($after -ge $remaining) { throw "Firewall rule '$name' is still present after removal. Check permissions or Group Policy." }
            $remaining = $after
        }
    }
    if (-not $settings.removeOnly) {
        # Offline machines can throw instead of returning an empty collection.
        # Only this discovery call falls back; rule-creation errors stay fatal.
        try { $active = @(Get-NetConnectionProfile -ErrorAction Stop | Select-Object -ExpandProperty NetworkCategory) }
        catch { $active = @() }
        $fwProfiles = @('Private')
        if ($active -contains 'Public') { $fwProfiles += 'Public' }
        if ($active -contains 'DomainAuthenticated') { $fwProfiles += 'Domain' }
        $profileArg = ($fwProfiles | Select-Object -Unique) -join ','
        New-NetFirewallRule -DisplayName 'Couchside Agent' -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort $Port -Profile $profileArg -ErrorAction Stop | Out-Null
        New-NetFirewallRule -DisplayName 'Couchside Agent HTTPS' -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort ($Port + 1) -RemoteAddress LocalSubnet -Profile $profileArg -ErrorAction Stop | Out-Null
        New-NetFirewallRule -DisplayName 'Couchside Agent Discovery' -Direction Inbound -Action Allow `
            -Program $settings.program -Protocol UDP -LocalPort $Port `
            -RemoteAddress LocalSubnet -Profile $profileArg -ErrorAction Stop | Out-Null
        Write-Output "Firewall: TCP $Port; local-subnet HTTPS + discovery; profiles $profileArg."
    }
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
'@
    Invoke-InstallerWorker -Code $worker.Replace('__SETTINGS__',$data64) -Label 'Couchside firewall configuration'
}
# END firewall helpers

function Stop-AgentTask {
    # Do not stop the working agent until firewall setup has succeeded.
    if (-not $Uninstall) {
        try { Set-CouchsideFirewall }
        catch { throw "Firewall setup failed before stopping the existing agent: $_" }
    }
    # Stop-ScheduledTask kills a running instance; Unregister does NOT, so an
    # upgrade must stop first or copying over the running files/exe conflicts.
    #
    # But Stop-ScheduledTask only ends an instance the TASK still tracks, and a
    # logon-launched agent routinely outlives that: measured on a real box, the
    # task read "Ready" while couchside-agent.exe was very much alive. Nothing
    # was stopped, the .exe stayed locked, and the upgrade died on
    # "Copy-Item ... because it is being used by another process" -- which Inno
    # then reported as a successful install. So also stop the process by name,
    # and WAIT for the handle to drop (process exit is asynchronous, and copying
    # a millisecond too early fails exactly the same way).
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Get-Process -Name 'couchside-agent' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    $exe = Join-Path $InstallDir 'couchside-agent.exe'
    if (Test-Path $exe) {
        foreach ($i in 1..20) {           # up to ~5s, then let the copy report
            try {
                $fs = [IO.File]::Open($exe, 'Open', 'ReadWrite', 'None')
                $fs.Close()
                break
            } catch { Start-Sleep -Milliseconds 250 }
        }
    } else {
        Start-Sleep -Milliseconds 500
    }
}

function Uninstall-Couchside {
    Write-Host 'Uninstalling Couchside agent...'
    Stop-AgentTask
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    try { Set-CouchsideFirewall -RemoveOnly }
    catch { Write-Warning "Could not remove Couchside firewall rules: $_ Agent cleanup will continue; these rules may need manual removal." -WarningAction Continue }
    # Tray widget: kill the running icon + remove its Startup shortcut.
    Get-CimInstance Win32_Process -Filter "Name='pythonw.exe' OR Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*couchside-tray.pyw*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if (Test-Path $StartupLnk) { Remove-Item -Force $StartupLnk -ErrorAction SilentlyContinue }
    # Remove our ms-gamebar no-op handlers, but only if they are still OURS
    # (command == systray.exe): never clobber a real Game Bar the user may have
    # reinstalled since.
    foreach ($s in 'ms-gamebar','ms-gamebarservices','ms-gamingoverlay') {
        $b = "HKCU:\Software\Classes\$s"
        $cmd = (Get-ItemProperty "$b\shell\open\command" -Name '(default)' -ErrorAction SilentlyContinue).'(default)'
        if ($cmd -eq 'systray.exe') { Remove-Item $b -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir }
    Write-Host "Left in place (delete manually to unpair phones): $DataDir"
    Write-Host 'Note: if install disabled hibernation, restore it with `powercfg /hibernate on`.'
    Write-Host 'Kept Python and the ViGEmBus driver (uninstall from Apps & features if unwanted).'
    Write-Host 'Done.'
}

if ($Uninstall) { Uninstall-Couchside; exit 0 }

function Test-RealPython3 {
    # True if $exe runs and is Python 3. The Microsoft Store stub exits nonzero
    # (it just opens the Store), so this rejects it.
    param([string]$exe)
    if (-not $exe -or ($exe -like '*\Microsoft\WindowsApps\*')) { return $false }
    try {
        $v = & $exe -c 'import sys; print(sys.version_info[0])' 2>$null
        return ($LASTEXITCODE -eq 0 -and "$v".Trim() -eq '3')
    } catch { return $false }
}

function Resolve-Python {
    # Full path to a real Python 3 (pythonw.exe preferred so the task is
    # windowless), or $null. Robust to a stale PATH (right after installing
    # Python) and per-user vs machine installs: checks PATH, the `py` launcher,
    # and the well-known python.org install dirs.
    $cands = @()
    foreach ($n in 'pythonw.exe','python.exe') {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) { $cands += $c.Source }
    }
    $pyl = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($pyl) {
        try {
            $exe = & $pyl.Source -3 -c 'import sys; print(sys.executable)' 2>$null
            if ($LASTEXITCODE -eq 0 -and $exe) {
                $pw = Join-Path (Split-Path $exe) 'pythonw.exe'
                if (Test-Path $pw) { $cands += $pw }
                $cands += $exe
            }
        } catch { }
    }
    $bases = @($env:ProgramFiles, ${env:ProgramFiles(x86)},
               (Join-Path $env:LOCALAPPDATA 'Programs\Python'))
    foreach ($base in $bases) {
        if (-not $base -or -not (Test-Path $base)) { continue }
        Get-ChildItem -Path $base -Filter 'Python3*' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            foreach ($exe in 'pythonw.exe','python.exe') {
                $f = Join-Path $_.FullName $exe
                if (Test-Path $f) { $cands += $f }
            }
        }
    }
    foreach ($c in $cands) {
        $probe = $c
        if ($c -like '*pythonw.exe') {
            $pe = Join-Path (Split-Path $c) 'python.exe'
            if (Test-Path $pe) { $probe = $pe } else { continue }
        }
        if (Test-RealPython3 $probe) { return $c }
    }
    return $null
}

function Get-Winget {
    $w = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($w -and $w.Source -notlike '*\Microsoft\WindowsApps\*') { return $w.Source }
    # The WindowsApps alias is the real winget on a machine that has App
    # Installer; only reject it if it doesn't actually run.
    if ($w) {
        try { & $w.Source --version 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { return $w.Source } } catch { }
    }
    return $null
}

function Install-WingetPackage {
    param([string]$Id, [string]$Label, [string]$Version = "")
    $wg = Get-Winget
    if (-not $wg) { return $false }
    Write-Host "Installing $Label via winget ($Id)..."
    $args = @('install','--id',$Id,'--exact','--silent','--accept-package-agreements','--accept-source-agreements','--disable-interactivity')
    if ($Version) { $args += @('--version',$Version) }
    & $wg @args 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    return $true
}

function Assert-ReleaseSignature {
    param([string]$Python, [string]$Sums, [string]$Signature, [string[]]$Keys)
    if (-not (Test-Path -LiteralPath $Signature)) { throw 'Release signature missing; existing agent retained.' }
    $verifyScript = @'
import sys
from cryptography.hazmat.primitives.serialization import load_pem_public_key
message = open(sys.argv[1], 'rb').read()
signature = open(sys.argv[2], 'rb').read()
for pem in sys.argv[3:]:
    try:
        load_pem_public_key(pem.encode('ascii')).verify(signature, message)
        sys.exit(0)
    except Exception:
        pass
sys.exit(1)
'@
    & $Python -c $verifyScript $Sums $Signature @Keys
    if ($LASTEXITCODE -ne 0) { throw 'Release signature verification failed; existing agent retained.' }
    Write-Host 'Release signature: verified (maintainer key).'
}

# --- 1. resolve the agent source: local checkout, else download --------------
$here    = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { $null }
$usePython = $true
$pyPath  = $null

function Find-Local {
    # First existing candidate under $here, or $null. Candidates are given
    # relative to the script so this works whether the installer is run from
    # the repo ROOT (this file's home, mirroring install.sh -> agent files
    # live under agent\win\) or from a standalone agent\win\ folder.
    param([string[]]$rels)
    if (-not $here) { return $null }
    foreach ($r in $rels) {
        $p = Join-Path $here $r
        if (Test-Path $p) { return $p }
    }
    return $null
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

$localExe = Find-Local @('couchside-agent.exe','agent\win\couchside-agent.exe')
$localPy  = Find-Local @('couchsided-win.py','agent\win\couchsided-win.py')
$localQr  = Find-Local @('qr.py','agent\qr.py','..\qr.py','agent\win\qr.py')
$localTray = Find-Local @('couchside-tray.pyw','agent\win\couchside-tray.pyw')
$localDll = Find-Local @('ViGEmClient.dll','agent\win\ViGEmClient.dll')

if ($localExe) {
    # Resolve the firewall program before the pre-stop configuration check.
    $usePython = $false
    Stop-AgentTask
    # Prebuilt exe: no Python needed.
    Copy-Item $localExe (Join-Path $InstallDir 'couchside-agent.exe') -Force
    Write-Host 'Using local couchside-agent.exe'
    if ($localQr)  { Copy-Item $localQr  (Join-Path $InstallDir 'qr.py') -Force }
    if ($localDll) { Copy-Item $localDll (Join-Path $InstallDir 'ViGEmClient.dll') -Force }
}
else {
    # Python path (local checkout or web download). Ensure Python first.
    $pyPath = Resolve-Python
    if (-not $pyPath) {
        if (-not (Install-WingetPackage 'Python.Python.3.12' 'Python 3.12')) {
            throw 'Python 3 is required and winget is unavailable. Install Python 3 from https://python.org (check "Add to PATH"), then re-run.'
        }
        $pyPath = Resolve-Python
        if (-not $pyPath) { throw 'Python installed but could not be located. Open a new PowerShell and re-run the installer.' }
    }
    Write-Host "Using Python: $pyPath"
    # TLS certificate creation is bundled in the exe, but Python installs need
    # the same reviewed PyCA dependency. Never silently claim HTTPS is ready.
    $consolePy = Join-Path (Split-Path $pyPath) 'python.exe'
    & $consolePy -m pip install --only-binary=:all: 'cryptography==46.0.7'
    if ($LASTEXITCODE -ne 0) { throw 'HTTPS dependency installation failed; existing task/config retained.' }


    if ($localPy) {
        Stop-AgentTask
        Copy-Item $localPy (Join-Path $InstallDir 'couchsided-win.py') -Force
        if ($localQr) { Copy-Item $localQr (Join-Path $InstallDir 'qr.py') -Force }
        if ($localTray) { Copy-Item $localTray (Join-Path $InstallDir 'couchside-tray.pyw') -Force }
        Write-Host 'Installed agent from local checkout.'
    } elseif ($UseRelease) {
        Write-Host 'Downloading signed agent from the latest release ...'
        $tmp = (New-Item -ItemType Directory -Force -Path (Join-Path $env:TEMP ("couchside-dl-" + [guid]::NewGuid().ToString('N')))).FullName
        try {
            $required = @('couchsided-win.py','qr.py')
            $optional = @('couchside-tray.pyw')
            foreach ($a in ($required + $optional)) {
                try { Invoke-WebRequest -UseBasicParsing "$ReleaseBase/$a" -OutFile (Join-Path $tmp $a) }
                catch { if ($required -contains $a) { throw "Could not download $a from the release: $_" } }
            }
            Invoke-WebRequest -UseBasicParsing "$ReleaseBase/SHA256SUMS" -OutFile (Join-Path $tmp 'SHA256SUMS')
            $sigPath = Join-Path $tmp 'SHA256SUMS.sig'
            try { Invoke-WebRequest -UseBasicParsing "$ReleaseBase/SHA256SUMS.sig" -OutFile $sigPath } catch { throw 'Release signature download failed; existing agent retained.' }

            # cryptography was provisioned above, before touching the old task.
            # Authentication failure never stops/replaces the running agent.
            Assert-ReleaseSignature -Python $consolePy -Sums (Join-Path $tmp 'SHA256SUMS') -Signature $sigPath -Keys $ReleasePubKeys

            # (2) INTEGRITY: every required file must match its SHA256SUMS entry.
            $sums = @{}
            foreach ($line in (Get-Content (Join-Path $tmp 'SHA256SUMS'))) {
                if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+)$') { $sums[$matches[2].Trim()] = $matches[1].ToLower() }
            }
            foreach ($a in $required) {
                if (-not $sums.ContainsKey($a)) { throw "SHA256SUMS has no entry for $a - refusing to install." }
                $got = (Get-FileHash (Join-Path $tmp $a) -Algorithm SHA256).Hash.ToLower()
                if ($got -ne $sums[$a]) { throw "$a checksum mismatch - refusing to install (corrupt or tampered)." }
            }

            & $consolePy -m py_compile (Join-Path $tmp 'couchsided-win.py') (Join-Path $tmp 'qr.py')
            if ($LASTEXITCODE -ne 0) { throw 'Verified agent failed to compile; existing task retained.' }
            # Authentication, required checksums and syntax passed. Stop only now.
            Stop-AgentTask
            # Verified -> place the files.
            Copy-Item (Join-Path $tmp 'couchsided-win.py') (Join-Path $InstallDir 'couchsided-win.py') -Force
            Copy-Item (Join-Path $tmp 'qr.py')             (Join-Path $InstallDir 'qr.py') -Force
            $trayDl = Join-Path $tmp 'couchside-tray.pyw'
            $trayOk = (Test-Path $trayDl) -and $sums.ContainsKey('couchside-tray.pyw')
            if ($trayOk) { $trayOk = ((Get-FileHash $trayDl -Algorithm SHA256).Hash.ToLower() -eq $sums['couchside-tray.pyw']) }
            if ($trayOk) { Copy-Item $trayDl (Join-Path $InstallDir 'couchside-tray.pyw') -Force }
            & $pyPath -m py_compile (Join-Path $InstallDir 'couchsided-win.py')
            if ($LASTEXITCODE -ne 0) { throw 'Downloaded agent failed to compile - aborting.' }
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    } else {
        # Dev override: -Ref <branch> fetches raw, UNVERIFIED source from that ref.
        Write-Warning "Fetching UNVERIFIED agent from raw '$Ref' (no signature or checksum). Omit -Ref for a signed release install."
        Stop-AgentTask
        Write-Host "Downloading agent from $RawBase ..."
        Invoke-WebRequest -UseBasicParsing "$RawBase/win/couchsided-win.py" -OutFile (Join-Path $InstallDir 'couchsided-win.py')
        Invoke-WebRequest -UseBasicParsing "$RawBase/qr.py"                 -OutFile (Join-Path $InstallDir 'qr.py')
        try { Invoke-WebRequest -UseBasicParsing "$RawBase/win/couchside-tray.pyw" -OutFile (Join-Path $InstallDir 'couchside-tray.pyw') } catch {}
        & $pyPath -m py_compile (Join-Path $InstallDir 'couchsided-win.py')
        if ($LASTEXITCODE -ne 0) { throw 'Downloaded agent failed to compile - aborting.' }
    }
}

# The agent runs NON-elevated but rewrites config.json when launchers change;
# grant this user Modify on the data dir (the token's own ACL still overrides).
icacls $DataDir /grant "$($env:USERNAME):(OI)(CI)M" | Out-Null

# --- 2. virtual gamepad: ViGEmBus driver + client DLL (optional) --------------
if (-not $NoGamepad) {
    if (-not (Get-Service -Name ViGEmBus -ErrorAction SilentlyContinue)) {
        Install-WingetPackage 'ViGEm.ViGEmBus' 'ViGEmBus (virtual gamepad driver)' '1.22.0' | Out-Null
    }
    $dllDest = Join-Path $InstallDir 'ViGEmClient.dll'
    if (-not (Test-Path $dllDest)) {
        # Fetch the official redistributable ViGEmClient.dll out of the vgamepad
        # PyPI sdist (it ships prebuilt x64/x86 copies of Nefarius' client).
        #
        # PURE POWERSHELL, and deliberately NOT gated on $usePython. This used to
        # read `if (... -and $usePython -and $pyPath)` and shell out to a Python
        # snippet -- so an install that used the bundled .exe (which needs no
        # Python, and therefore has none) silently skipped the DLL entirely. The
        # ViGEmBus DRIVER still got installed by winget above, which made the box
        # look correctly set up while vigem_available() -- a DLL-load check --
        # returned false, caps.gamepad went false, and the app hid the Pad tab.
        # That is issue #255: reported as "the Pad tab is missing" on a .exe
        # install whose ViGEmBus.sys was present and fine.
        #
        # tar.exe is present on Windows 10 1803+ (bsdtar in System32).
        # Best-effort throughout: the gamepad is the only thing affected, so a
        # failure here must never abort an otherwise good install.
        try {
            $tmp = Join-Path $env:TEMP 'couchside-vigem'
            New-Item -ItemType Directory -Force -Path $tmp | Out-Null
            $sdist = 'https://files.pythonhosted.org/packages/8a/54/0eaddc33f84247963af078f364b37153d09fcd6cdc398f243ec3e8842c56/vgamepad-0.1.0.tar.gz'
            if ($sdist) {
                $tgz = Join-Path $tmp 'vgamepad.tar.gz'
                Invoke-WebRequest -Uri $sdist -OutFile $tgz -TimeoutSec 60 -UseBasicParsing
                if ((Get-FileHash -Algorithm SHA256 $tgz).Hash -ne '57F6BD01AEC0C172947517FB782D150EF9B285F7F4D524C317374FA5C24A89DE') { throw 'vgamepad source checksum mismatch' }
                & tar.exe -xzf $tgz -C $tmp 2>$null
                $hit = Get-ChildItem $tmp -Recurse -Filter 'ViGEmClient.dll' -ErrorAction SilentlyContinue |
                       Where-Object { $_.FullName -match '\\x64\\' } | Select-Object -First 1
                if ($hit) {
                    if ((Get-FileHash -Algorithm SHA256 $hit.FullName).Hash -ne '2BF0CB1D809039573C922737D298A1653D4DBC61408060FF45A9BCFDE82E97D2') { throw 'ViGEmClient checksum mismatch' }
                    Copy-Item $hit.FullName $dllDest -Force
                }
            }
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        } catch { }
    }
    if (Test-Path $dllDest) { Write-Host 'Virtual gamepad ready (ViGEmBus + client DLL).' }
    else { Write-Host 'Gamepad driver step incomplete; the pad may be unavailable (everything else works).' }

    # Silence the "Get an app to open this 'ms-gamebar' link" popup. Windows
    # globally binds the Xbox *Guide* button to Xbox Game Bar; the app's Guide
    # button drives that bit on the virtual pad, so on a box where Game Bar has
    # been uninstalled every Guide press dead-ends in that dialog. Point the
    # Game Bar URI schemes at a no-op (systray.exe exits instantly) so Windows
    # opens nothing instead. Written to HKCU of the installing user, which is
    # the agent's target user ($env:USERNAME - same identity the scheduled task
    # below runs as); no effect on other accounts, reversible on --uninstall,
    # no reboot. Steam Big Picture still intercepts Guide first while it is
    # running, so this only changes the "nothing else handled Guide" case.
    foreach ($s in 'ms-gamebar','ms-gamebarservices','ms-gamingoverlay') {
        try {
            $b = "HKCU:\Software\Classes\$s"
            New-Item "$b\shell\open\command" -Force | Out-Null
            Set-ItemProperty $b '(default)'    "URL:$s"
            Set-ItemProperty $b 'URL Protocol' ''
            Set-ItemProperty "$b\shell\open\command" '(default)' 'systray.exe'
        } catch { }
    }
    Write-Host 'Silenced the Xbox Game Bar (ms-gamebar) popup for the Guide button.'
}

# --- 3. token (kept across reinstalls so paired phones keep working) ---------
if (-not (Test-Path $TokenPath)) {
    $bytes = New-Object byte[] 24
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $token = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    [IO.File]::WriteAllText($TokenPath, $token)  # BOM-less, no trailing newline
    # Language-neutral SIDs (English "Administrators" fails on localized Windows):
    # S-1-5-18 SYSTEM, S-1-5-32-544 Administrators, plus the installing user.
    icacls $TokenPath /inheritance:r /grant:r '*S-1-5-18:R' '*S-1-5-32-544:F' "$($env:USERNAME):R" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed to restrict $TokenPath (exit $LASTEXITCODE)" }
    Write-Host "Created token: $TokenPath"
} else {
    Write-Host "Kept existing token: $TokenPath"
}

# --- 4. initial config (kept across reinstalls) -------------------------------
if (-not (Test-Path $ConfigPath)) {
    $config = [ordered]@{
        port  = $Port
        units = @( [ordered]@{ name = 'Audiosrv'; scope = 'system' } )
        actions = [ordered]@{
            'restart-explorer' = [ordered]@{
                label = 'Restart Explorer'
                description = 'Restart the Windows shell (explorer.exe), fixes a wedged desktop/taskbar'
                danger = 'medium'
                cmd = @('powershell','-NoProfile','-Command','Stop-Process -Name explorer -Force; Start-Process explorer.exe')
            }
            'lock' = [ordered]@{
                label = 'Lock Screen'; description = 'Lock the Windows session'
                danger = 'low'; cmd = @('rundll32.exe','user32.dll,LockWorkStation')
            }
            'suspend' = [ordered]@{
                label = 'Suspend'
                description = 'Suspend the box to RAM; wake it from the app over Wake-on-LAN'
                danger = 'medium'
                cmd = @('rundll32.exe','powrprof.dll,SetSuspendState','0,1,0'); detached = $true
            }
            'reboot' = [ordered]@{
                label = 'Reboot'; description = 'Reboot the box'; danger = 'high'
                cmd = @('shutdown','/r','/t','0'); detached = $true
            }
            'poweroff' = [ordered]@{
                label = 'Power Off'; description = 'Power off the box'; danger = 'high'
                cmd = @('shutdown','/s','/t','0'); detached = $true
            }
        }
        action_order = @('restart-explorer','lock','suspend','reboot','poweroff')
    }
    if (Get-Service -Name 'Steam Client Service' -ErrorAction SilentlyContinue) {
        $config.units += [ordered]@{ name = 'Steam Client Service'; scope = 'system' }
    }
    $json = $config | ConvertTo-Json -Depth 6
    # BOM-less UTF-8: PS 5.1's `Set-Content -Encoding utf8` prepends a BOM,
    # which json.load rejects (the agent would fall back to built-in defaults).
    [IO.File]::WriteAllText($ConfigPath, $json + "`n")
    Write-Host "Created config: $ConfigPath"
} else {
    Write-Host "Kept existing config: $ConfigPath"
    if ($PortWasSpecified) { Save-ExplicitInstallerPort -RequestedPort $Port -Path $ConfigPath }
}

# --- 5. hibernate off so SetSuspendState means SLEEP, not hibernate ----------
if (-not $KeepHibernate) {
    & powercfg /hibernate off | Out-Null
    Write-Host 'Disabled hibernation (so Suspend sleeps to RAM; -KeepHibernate to skip).'
}

# Firewall rules are configured by Stop-AgentTask before stopping the old agent.

# --- 7. scheduled task: at logon, current user, interactive, non-elevated ----
# No --port argument: the agent reads the port from config.json, so a config
# edit is honored after a restart (matches the Linux systemd unit).
if ($usePython) {
    $exe = $pyPath
    $arg = ('"{0}"' -f (Join-Path $InstallDir 'couchsided-win.py'))
} else {
    $exe = Join-Path $InstallDir 'couchside-agent.exe'
    $arg = $null
}
$action = if ($arg) {
    New-ScheduledTaskAction -Execute $exe -Argument $arg -WorkingDirectory $InstallDir
} else {
    New-ScheduledTaskAction -Execute $exe -WorkingDirectory $InstallDir
}
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
# Discoverable choice, never the silent default: if the user didn't decide via a
# flag and we have a console to ask in (a human running install.ps1, not the
# silent CouchsideSetup.exe path), prompt - defaulting to No. They can also flip
# it later from the tray icon.
if (-not $Elevated -and -not $NoElevated -and -not $FromInstaller -and [Environment]::UserInteractive) {
    Write-Host ""
    Write-Host "Let the phone control ADMIN windows (games with anticheat, admin apps)?" -ForegroundColor Cyan
    Write-Host "  Windows blocks a normal program from controlling admin windows, so to reach"
    Write-Host "  them the agent has to run as administrator. Trade-off: a phone holding this"
    Write-Host "  box's token could then drive admin app windows. Most people don't need this."
    Write-Host "  You can change it any time from the Couchside tray icon." -ForegroundColor DarkGray
    $ans = Read-Host "  Control admin windows? [y/N]"
    if ($ans -match '^\s*(y|yes)\s*$') { $Elevated = $true }
}
# -RunLevel Limited (non-elevated) is the default + least-privilege posture. With
# -Elevated the at-logon task runs Highest (admin) with NO UAC prompt, so the
# phone's mouse/keyboard can drive ADMIN app windows that Windows UIPI otherwise
# blocks a non-elevated agent from. Only works for an ADMIN account (Highest can't
# elevate a standard user). Opt-in; the tradeoff is documented in agent/win/README.
$runLevel = if ($Elevated) { 'Highest' } else { 'Limited' }
if ($Elevated) {
    Write-Host "  agent task will run ELEVATED (Highest) - the phone can control admin windows." -ForegroundColor Yellow
    Write-Host "  (A LAN token holder can then drive admin app windows via virtual input; the" -ForegroundColor Yellow
    Write-Host "   command allowlist still holds. Re-run without -Elevated to revert.)" -ForegroundColor Yellow
}
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel $runLevel
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0)

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings | Out-Null
Start-ScheduledTask -TaskName $TaskName
Write-Host "Scheduled task '$TaskName' registered and started."

# --- 7b. tray widget: Startup shortcut + launch now (Python installs only) ----
# The tray is a .pyw GUI (needs Python + tkinter); the prebuilt-exe path has no
# interpreter to run it, so it is skipped there. Runs windowless under
# pythonw.exe, in the interactive user session (a Startup shortcut, like any
# tray app) - never elevated.
$trayPy = Join-Path $InstallDir 'couchside-tray.pyw'
if ($usePython -and (Test-Path $trayPy)) {
    # Prefer pythonw.exe (no console flash); fall back to whatever we resolved.
    $pyw = $pyPath
    if ($pyPath -notlike '*pythonw.exe') {
        $sib = Join-Path (Split-Path $pyPath) 'pythonw.exe'
        if (Test-Path $sib) { $pyw = $sib }
    }
    try {
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut($StartupLnk)
        $lnk.TargetPath = $pyw
        $lnk.Arguments = '"{0}"' -f $trayPy
        $lnk.WorkingDirectory = $InstallDir
        $lnk.WindowStyle = 7           # minimized (belt-and-suspenders; pythonw is windowless)
        $lnk.Description = 'Couchside tray widget'
        $lnk.Save()
        Write-Host "Tray widget: added to Startup ($StartupLnk)."
    } catch { Write-Host "Tray widget: could not create Startup shortcut ($_)." }
    # Launch it now so it appears in the tray immediately (kill a stale one first).
    Get-CimInstance Win32_Process -Filter "Name='pythonw.exe' OR Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*couchside-tray.pyw*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    try { Start-Process $pyw -ArgumentList ('"{0}"' -f $trayPy) -WorkingDirectory $InstallDir } catch {}
}

# --- 8. pairing --------------------------------------------------------------
# Same closing instructions as install.sh, in the same order: what got installed,
# then GET THE APP -> Scan for boxes -> type the PIN. Someone who sets up a
# Windows box and a Steam Deck must not be told two different stories, and the
# old text named neither the app stores nor the PIN step the /pair page teaches.
$hostShort = $env:COMPUTERNAME.ToLower()
Write-Host ''
Write-Host '=================================================================='
Write-Host " Couchside agent is running on $hostShort.local:$Port"
Write-Host ''
Write-Host " Token file: $TokenPath"
Write-Host '=================================================================='
Write-Host ''
Write-Host 'On your phone: install Couchside (App Store / Google Play), open it, go to'
Write-Host 'the Setup tab and tap Scan for boxes - or point your camera at the QR on'
Write-Host 'the pairing page. A 6-digit PIN will appear on this screen; type it in to pair.'
Write-Host ''
Write-Host "To re-show this later: open  http://localhost:$Port/pair  on THIS machine,"
Write-Host 'or use the Couchside tray icon.'
# The pairing page carries the store QR for someone who does not have the app
# yet, so open it on the box's own screen exactly like install.sh does.
try { Start-Process "http://localhost:$Port/pair" -ErrorAction Stop } catch {
    Write-Host " (open the pairing page manually: http://localhost:$Port/pair)"
}
