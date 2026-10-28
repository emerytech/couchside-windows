# Windows preview validation

Mirrors the product-monorepo validation record in `docs/WINDOWS_HTTPS_PREVIEW.md`.

## VM installer validation (2026-10-27; publication on hold)

The actual Inno wrapper from Windows mirror commit `8e3ccc9` / CI run
`40066571993` passed unattended clean app-data installation and an in-place
upgrade on the owner's authorized Windows VM copy. The physical source PC was
left intact. This package also includes the normal-privilege foreground warning
from monorepo PR #645 / Windows mirror PR #5.

- Clean installation began without the agent's application-data or identity
  directories and without its scheduled task. It generated a different pairing
  token and TLS certificate, installed the packaged executable, and registered
  a Limited interactive logon task. The agent became healthy in the signed-in
  desktop session, advertised TLS, and owned no top-level window.
- The original identity directories were then restored. A real-wrapper upgrade
  preserved all four original token/config/certificate/private-key hashes and
  their file ACLs. The packaged agent again started windowlessly in the user
  session with Limited privileges.
- A 75,776-byte authenticated HTTPS upload, trusting the existing local
  certificate, matched the destination hash. Only its randomly named synthetic
  file was removed.
- The VM reboot was verified by a changed Windows boot timestamp. Before user
  sign-in, the task correctly remains Ready and the agent does not run in
  service session 0. The post-reboot user-logon check is still pending.

Installer SHA-256:
`4fafb94c69d5610f558776e971f9e880d2b742754f65521824ad3b9253c269bd`.
Installed agent SHA-256:
`9bce54559b0816576e91b556150e70fd794be28331eaf53244dbc1e17cf84be7`.

The VM had the ViGEm driver already installed. This does not claim a first-ever
driver installation, interactive wizard/UAC consent verification, or a passed
post-reboot logon test. A VM snapshot and protected Couchside-only backups remain
available for rollback. Raw logs, identity files and machine-specific test helpers
remain private. No merge, release, update-manifest change or store submission was
performed.


## Combined candidate upgrade validation (2026-10-28; publication on hold)

The owner-authorized Windows VM was upgraded with the actual Inno wrapper from
runtime source `5c96b4d` / build run `40523441131`. The original physical PC was
inspected read-only and was not upgraded or rebooted in this pass. A protected
Couchside-only backup and a VM disk/EFI/TPM snapshot were retained.

- The old installation started automatically at the owner's initial desktop
  sign-in. The candidate replaced the installed executable with the expected
  `dba4c5f...` hash. Both binaries report `0.4.14-win`, so the executable hash,
  rather than the version label, proves the upgrade.
- The first unattended wrapper log recorded installation success. Its remote
  harness timed out after the installer had exited; it used PowerShell
  `Start-Process -Wait`, which can also wait for descendant processes. A repeat
  installation waited only for the installer process and
  returned exit code 0; no installer code was changed to work around the harness.
- Pairing token, configuration (including its existing backup), TLS certificate
  and private key retained their original bytes and file ACLs. No uninstall,
  re-pairing, certificate replacement, or phone-data reset was performed.
- The candidate ran under the Limited/Interactive task in the signed-in desktop.
  Its expected PyInstaller parent/child pair had no main window handles; a single
  child owned both HTTP and HTTPS listeners. This is not a second agent instance.
- The existing token authenticated status. An HTTPS smoke check trusted the
  existing certificate with hostname validation enabled. A 65,581-byte synthetic
  upload matched its destination; only that test file was removed. Status without
  authentication returned 401 and plaintext upload returned 426.
- A guest reboot was confirmed by a changed Windows boot timestamp. Before
  subsequent user sign-in, the task correctly remained Ready and no agent ran.
  **The candidate's post-reboot user-sign-in/startup check is still pending.**

Installer SHA-256:
`68eecd3015edfa88e709547c962792d0daafdc7fb47b2cfdc00b75d6386bd646`.
Installed agent SHA-256:
`dba4c5fbe53db1dad39cca4d6023c8733b8472b0313d2bd0f17ab8d4abd58674`.

This pass does not claim phone reconnection, physical-PC compatibility, first-ever
ViGEm installation, or interactive wizard/UAC consent verification. The candidate
remains unsigned by Authenticode. Store submission, release publication, public
update-manifest changes, and email sends remain on hold.
