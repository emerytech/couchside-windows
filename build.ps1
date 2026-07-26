# Build a self-contained couchside-agent.exe with PyInstaller, so end users
# don't need Python installed. Run on a Windows machine with Python 3.9+:
#
#   powershell -ExecutionPolicy Bypass -File build.ps1
#
# Output: dist\couchside-agent.exe. Drop it (optionally with ViGEmClient.dll)
# next to this script in agent\win\ — the root install.ps1 finds an exe there
# and installs it instead of downloading the Python agent.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

python -m pip install --upgrade pyinstaller | Out-Null

# qr.py is the shared encoder in agent/; a standalone copy may sit next to
# this script. Put both on PyInstaller's module search path so `import qr`
# resolves either way.
$qrPath = $here
if (-not (Test-Path (Join-Path $here 'qr.py'))) { $qrPath = Split-Path $here -Parent }

# --noconsole would swallow the log prints; keep the console build and let the
# scheduled task hide the window instead. qr.py is bundled as a module; the
# ViGEmClient.dll (if present next to this script) is bundled as data so the
# _MEIPASS lookup in _load_vigem finds it.
$piArgs = @(
    '--onefile',
    '--name', 'couchside-agent',
    '--paths', $here,
    '--paths', $qrPath,
    '--hidden-import', 'qr',
    # Pin outputs under agent/win regardless of the invoker's cwd, so the
    # "Built:" path below (and the README instructions) are always right.
    '--distpath', (Join-Path $here 'dist'),
    '--workpath', (Join-Path $here 'build'),
    '--specpath', $here
)
$dll = Join-Path $here 'ViGEmClient.dll'
if (Test-Path $dll) { $piArgs += @('--add-binary', "$dll;.") }

# Brand icon. Without it PyInstaller stamps its own default, which is what the
# user sees in Explorer, Task Manager, and — because the installer points
# UninstallDisplayIcon at this exe — the Apps & features list. Look for the icon
# the same two ways qr.py is resolved above: next to this script (the
# couchside-windows repo, where the sync drops it at the root) or in brand\ two
# levels up (the monorepo, agent\win -> brand). Optional: a checkout without it
# still builds.
$ico = @(
    (Join-Path $here 'couchside.ico'),
    (Join-Path (Split-Path (Split-Path $here -Parent) -Parent) 'brand\couchside.ico')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($ico) { $piArgs += @('--icon', $ico) } else { Write-Host 'No couchside.ico found - building with the default PyInstaller icon.' }
$piArgs += (Join-Path $here 'couchsided-win.py')

python -m PyInstaller @piArgs

Write-Host ''
Write-Host "Built: $(Join-Path $here 'dist\couchside-agent.exe')"
