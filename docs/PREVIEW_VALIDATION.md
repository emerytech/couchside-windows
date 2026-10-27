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
