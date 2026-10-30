# Couchside for Windows

The open-source (MIT) **Windows agent** for **[Couchside](https://couchside.tv)** — it turns a
Windows gaming PC into something your phone can drive: launch games onto the big screen, be the
controller / trackpad / keyboard, control the TV, and glance at what the box is doing. **LAN-only,
bearer-token-authed, no cloud, no accounts, no analytics.**

The Couchside **phone app** (App Store / Google Play) is a separate, source-available product. This
**agent is MIT**, so anyone is free to build their own client against it.

> The Linux/SteamOS/Bazzite agent lives in the main Couchside project; this repository is the Windows
> agent, kept in sync from the product monorepo (the source of truth).

## Install

In an ordinary PowerShell window:
```powershell
irm https://couchside.tv/install.ps1 | iex
```
It installs a small background service (a scheduled task that runs as you, not elevated), a firewall
rule for the LAN, the ViGEmBus controller driver (Microsoft-signed, via `winget`), and a tray widget.
The installer verifies an offline **Ed25519 signature + SHA-256 checksums** over the release assets
before writing a single file, and refuses to continue if either fails.

## What it does
- **Launch games** — discovers installed Steam games and lays them out as cover art; tap to launch.
  Add custom launchers for anything else.
- **Virtual controller** — a genuine virtual Xbox 360 pad via **ViGEmBus**, plus mouse/trackpad and a
  keyboard bar that types straight to the PC.
- **TV control** — drive a Roku (and, as backends land, more brands) over your network.
- **Now-playing + vitals + one-tap actions** (restart Explorer, lock, sleep, wake, reboot, power off).
- **Screen preview + pairing** — a screenshot of the PC on demand; pair by QR or a 6-digit PIN.
- **Tray widget** — start/stop the agent, show the pairing QR, toggle start-at-logon.

## Requirements
- Windows 10 / 11.
- The controller needs **ViGEmBus** (installed automatically). Mouse/keyboard need nothing extra.
- Your phone and PC on the same LAN.

## Build a standalone .exe
`build.ps1` produces a self-contained `couchside-agent.exe` via PyInstaller, so end users need no
Python. Release builds run without a console; diagnostics remain in the rotating
`%LOCALAPPDATA%\Couchside\logs\agent.log` file. Use `build.ps1 -Console`
only for a developer build with terminal output.
```powershell
powershell -ExecutionPolicy Bypass -File build.ps1
```

## Security model
The agent runs as your Windows user on a home LAN behind one bearer token. It executes **only what is
on an explicit allowlist** — client input never becomes a command, a path, or a shell string. Every
state-changing route requires the token; remote launcher-creation and self-update are off by default.
See the header of `couchsided-win.py`.

## License
MIT — see [LICENSE](LICENSE). The phone app is licensed separately (source-available, PolyForm
Noncommercial) and is not part of this repository.

## HTTPS and file transfers (0.4.13 preview)

The HTTPS listener uses the HTTP port plus one (8788 by default). Existing
HTTP controls and pairing tokens are retained; newly paired clients receive
certificate fingerprints in the on-box QR/PIN flow and can pin the server.
`GET /api/tls/cert` publishes only the public certificate, never its private key.
For existing phones, use secure pairing/upgrade in the app; enabling HTTPS on
the box does not retrospectively encrypt an old HTTP connection.

Python installations require `cryptography==46.0.7` for certificate creation;
the executable build bundles it. Private keys live in the current user's
`%LOCALAPPDATA%\Couchside\tls`, with inheritance removed and access restricted
to that user and SYSTEM. The same key is retained across restarts and address
changes. A broken existing key is not silently replaced. `--no-tls` disables
the new listener and upload capability without removing legacy controls.

File transfers are opt-in operations from the paired app:

- `POST /api/upload?name=filename` streams into `~/Downloads/Couchside`.
- Requires HTTPS and either the bearer token or a short-lived, single-use
  ticket minted through authenticated HTTPS `POST /api/ticket?once=1`.
- Plain HTTP uploads are rejected; no plaintext fallback exists.
- Windows device names, path traversal, alternate data streams, and invalid
  filename characters are rejected. Existing files are never overwritten.
- Maximum 8 GiB per request, two uploads concurrently, bounded worker count,
  read deadlines, a free-space reserve, and temporary-file cleanup on failure.
- Uploading never runs or automatically opens the transferred file.
- `POST /api/upload/reveal` opens only the fixed destination folder on request.

The installer adds a LocalSubnet-scoped HTTPS firewall rule. Custom listener
ports use `--tls-port`; update the firewall explicitly when overriding it.
If HTTPS initialization fails, existing HTTP control remains usable but
`caps.file_upload` is false and uploads stay unavailable.

Regression checks: `python tests/test_https_upload.py`, plus `tests/test_win_*.py`.
No production release is implied by this preview branch.
