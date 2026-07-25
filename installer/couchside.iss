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
; Always leave a log in %TEMP% (Setup Log*.txt). The real install work happens in
; a hidden PowerShell child, so when it fails the log is the only breadcrumb —
; the failure message below points users at it.
SetupLogging=yes

[Files]
; Staged together so install.ps1's Find-Local sees couchside-agent.exe beside it.
Source: "..\dist\couchside-agent.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\install.ps1";              DestDir: "{app}"; Flags: ignoreversion
Source: "..\couchside-tray.pyw";       DestDir: "{app}"; Flags: ignoreversion
; KEEP THIS ENTRY LAST. Its AfterInstall hands off to the real installer, which
; needs every file above already staged in {app}. AfterInstall runs INSIDE the
; install step, which is the whole point — see [Code].
Source: "..\qr.py";                    DestDir: "{app}"; Flags: ignoreversion; \
  AfterInstall: RunAgentInstaller

[UninstallRun]
; Mirror uninstall through the same tested path (removes the task, firewall
; rule, tray, and — after asking — the pairing token).
;
; This one stays a passive [UninstallRun] on purpose: [UninstallRun] ignores exit
; codes, and for UNINSTALL that leniency is what we want. A helper that fails
; half-way must not abort the uninstall and strand the user with an entry in
; Apps & features they can never remove. Install is the opposite case — see [Code].
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\install.ps1"" -Uninstall -FromInstaller"; \
  Flags: runhidden waituntilterminated; RunOnceId: "CouchsideAgentUninstall"

[Code]
{ Hand off to the real installer, and REPORT ITS EXIT CODE.

  This was a [Run] entry until 2026-07-25. Inno's [Run] section never inspects
  exit codes: when install.ps1 failed (exit 1 — confirmed on real hardware, the
  Inno log read "Process exit code: 1") the wizard still displayed "Setup
  completed successfully", and `runhidden` meant the error text was invisible.
  A user upgraded, saw a green wizard, and kept running the old agent.

  Exec() hands back ResultCode, so a non-zero code can raise. The specific bug
  behind that incident was fixed in install.ps1 (it now stops the running agent
  before copying over it), but any FUTURE failure in there — winget, signature/
  checksum mismatch, py_compile — would have been swallowed the same way.

  WHY AN AfterInstall HOOK AND NOT CurStepChanged(ssPostInstall): ssPostInstall
  runs after Inno has already logged "Installation process succeeded", so an
  exception there is reported and then IGNORED — measured on Windows 2026-07-25,
  the log showed "CurStepChanged raised an exception" and Setup still exited 0.
  An AfterInstall function runs inside the install step, where an exception
  aborts Setup for real: rollback, a failure dialog, and a non-zero exit code. }

procedure RunAgentInstaller;
var
  ResultCode: Integer;
  Msg: String;
begin
  WizardForm.StatusLabel.Caption :=
    'Installing the Couchside agent (ViGEmBus, service, firewall)...';

  { Same command line the [Run] entry used, including -FromInstaller: it makes
    install.ps1's UAC self-elevation WAIT on the elevated child and mirror that
    child's exit code outward (and skip -NoExit, so no stray PowerShell window
    outlives the wizard). Without it we would be reading the exit code of the
    async RunAs handoff, which returns 0 instantly no matter what happens. }
  if not Exec('powershell.exe',
       '-NoProfile -ExecutionPolicy Bypass -File "' +
         ExpandConstant('{app}\install.ps1') + '" -FromInstaller',
       ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Msg := 'Setup could not start the Couchside installer script.' + #13#10 +
           'Windows said: ' + SysErrorMessage(ResultCode)
  else if ResultCode <> 0 then
    Msg := 'The Couchside agent installer failed (exit code ' +
           IntToStr(ResultCode) + ').' + #13#10 +
           'The agent on this PC was NOT installed or updated.'
  else
    Exit;   { 0 = the real install succeeded; say nothing, finish normally }

  { The real work runs hidden, so the actual error text is not on screen
    anywhere. Point at the two places it can still be recovered from.
    (Keep #13#10 off the start of a line — ISPP reads a leading # as a
    preprocessor directive and the compile fails with "Unknown preprocessor
    directive.") }
  Msg := Msg + #13#10#13#10 +
    'To see the actual error, open PowerShell and run it visibly:' + #13#10#13#10 +
    '    irm https://couchside.tv/install.ps1 | iex' + #13#10#13#10 +
    'Setup''s own log is in your %TEMP% folder (Setup Log*.txt).';

  { Aborts the wizard: no "Setup completed successfully" page, and Setup exits
    with a non-zero code. }
  RaiseException(Msg);
end;
