; Inno Setup script for CouchsideSetup.exe — a double-click installer for the
; Couchside Windows agent, so a mainstream gamer never touches PowerShell.
;
; It bundles the self-contained PyInstaller agent (couchside-agent.exe — no
; Python needed) plus the existing, tested install.ps1, and DELEGATES the real
; work to install.ps1's local-exe path (it finds couchside-agent.exe next to it,
; installs ViGEmBus via winget, fetches ViGEmClient.dll, and sets up the token,
; config, firewall rule, scheduled task, and tray). No install logic is
; duplicated here.
;
; Built in CI (build-installer.yml) on windows-latest: PyInstaller -> ISCC.
; MyAppVersion is passed by the CI via /DMyAppVersion=<agent-version>.

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0-dev"
#endif

[Setup]
AppId={{A9E2C6B1-6C3E-4E7B-9F1A-COUCHSIDEWIN}}
AppName=Couchside
AppVersion={#MyAppVersion}
AppPublisher=ETS3D LLC
AppPublisherURL=https://couchside.tv
DefaultDirName={localappdata}\Couchside\bootstrap
DisableProgramGroupPage=yes
; The agent installs to the user profile and runs as a non-elevated scheduled
; task; install.ps1 self-elevates only for the firewall rule + task creation. So
; the wrapper itself needs no admin — keep it a per-user install.
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=CouchsideSetup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName=Couchside (agent)
UninstallDisplayIcon={app}\couchside-agent.exe

[Files]
; Staged together so install.ps1's Find-Local sees couchside-agent.exe beside it.
Source: "..\dist\couchside-agent.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\install.ps1";              DestDir: "{app}"; Flags: ignoreversion
Source: "..\couchside-tray.pyw";       DestDir: "{app}"; Flags: ignoreversion
Source: "..\qr.py";                    DestDir: "{app}"; Flags: ignoreversion

[Run]
; Hand off to the real installer. -FromInstaller makes install.ps1's UAC self-
; elevation WAIT for the elevated child and skip -NoExit, so waituntilterminated
; below tracks the real install (not the instant async RunAs handoff) and no stray
; PowerShell window is left open after the wizard finishes.
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\install.ps1"" -FromInstaller"; \
  StatusMsg: "Installing the Couchside agent (ViGEmBus, service, firewall)..."; \
  Flags: runhidden waituntilterminated

[UninstallRun]
; Mirror uninstall through the same tested path (removes the task, firewall
; rule, tray, and — after asking — the pairing token).
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\install.ps1"" -Uninstall -FromInstaller"; \
  Flags: runhidden waituntilterminated; RunOnceId: "CouchsideAgentUninstall"
