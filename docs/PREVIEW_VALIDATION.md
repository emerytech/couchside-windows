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
runtime source `5c96b4d` / build run `40523441131`. The physical PC was initially
inspected read-only; its subsequent authorized upgrade is recorded below. A
protected Couchside-only backup and a VM disk/EFI/TPM snapshot were retained.

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
  The candidate then started automatically at the owner's post-reboot sign-in,
  without a manual task start. Task and process timestamps followed the new boot;
  the expected parent was Task Scheduler's `svchost.exe`. It remained Limited,
  in the interactive user session, with no main window handles and one listener
  owner. Identity/ACL comparison and the verified HTTPS upload passed again
  after reboot.

Installer SHA-256:
`68eecd3015edfa88e709547c962792d0daafdc7fb47b2cfdc00b75d6386bd646`.
Installed agent SHA-256:
`dba4c5fbe53db1dad39cca4d6023c8733b8472b0313d2bd0f17ab8d4abd58674`.

The VM pass does not claim phone reconnection, physical-PC compatibility, first-ever
ViGEm installation, or interactive wizard/UAC consent verification. The candidate
remains unsigned by Authenticode. Store submission, release publication, public
update-manifest changes, and email sends remain on hold.


## Physical Windows PC upgrade (2026-10-28; publication on hold)

After the VM checks passed, the owner confirmed the original Windows PC was free
for the same installer upgrade and one reboot. A protected Couchside-only backup
was made before replacing the executable. The same checksum-verified candidate
Inno wrapper returned exit code 0 on the physical PC.

- The old installed executable matched the VM baseline. Its replacement matches
  the expected `dba4c5f...` candidate hash.
- The existing pairing token, configuration and its backup, TLS certificate and
  private key retained all original bytes and file ACLs. The task stayed Limited
  and Interactive; the expected PyInstaller parent/child pair ran without main
  window handles, with one child serving both listeners.
- A verified-certificate HTTPS status/upload check passed again on this machine:
  a 65,581-byte synthetic file matched, unauthenticated status returned 401, and
  HTTP upload returned 426. Only the synthetic file was removed.
- An authorized normal Windows reboot was confirmed by a changed boot timestamp.
  Before subsequent sign-in the task was Ready and no agent ran, as intended.
  The saved Windows connection then completed normal user sign-in. The candidate
  started automatically from the logon task, without a manual task start, under
  Limited privileges in the interactive desktop. Its executable hash, identity
  bytes/ACLs, no-main-window process state, and single listener ownership still
  matched expectations. Verified HTTPS status and upload passed again after reboot.

Phone reconnection, real input/control behavior, and native phone uploads remain
separate validation gates. The installed ViGEm driver was already present; this
is not a first-ever driver-install result. No app release, main merge, production
manifest change, or subscriber send was performed.

The completed VM test agent was stopped after validation to avoid simultaneously
advertising a clone of the original PC's preserved pairing identity. Its logon task
and saved configuration were retained. The physical PC's candidate remains running.

## Android phone checks against the physical candidate (2026-10-28)

The owner's USB-connected Motorola Razr 2023 ran Direct `2.9.79 (48)` against
the same upgraded physical Windows candidate (`dba4c5f...`). No app reinstall,
data reset, new pairing, or agent privilege change was used for these checks.

- All three saved boxes remained in the selector. Selecting the existing Windows
  entry established a green, locked connection without a pairing prompt. Previously
  unlocked controls remained usable.
- Phone keyboard input reached a disposable Notepad document, including letters,
  numbers, spaces and punctuation. Backspace removed the expected character. A tap
  on Gboard's Done button inserted exactly one CRLF between two distinct markers,
  confirmed by reading the saved Windows file. Initial focus on Steam rather than
  Notepad was corrected before treating the typing result as meaningful.
- Native document-picker uploads of a 60-byte text file and an 8,388,608-byte binary
  file reached the Windows upload directory. Both destination sizes and SHA-256
  hashes matched the original fixtures. The app displayed the encrypted-transfer
  explanation; this candidate's HTTP-upload rejection was verified separately
  above. The small upload displayed its success message.
- After backgrounding and resuming the phone app, the saved Windows connection
  returned with its green lock. Mouse-pad movement and right-click opened Notepad's
  context menu at a new position; Escape dismissed it. Two phone Alt-Tab actions
  switched to Steam and back to Notepad without loss of the connection.
- Android's process-exit history contained no new crash/ANR entry during these
  checks. This is a functional smoke check, not the deferred long memory soak.

Follow-ups remain before calling phone QA complete:

- The larger upload arrived intact, but its success message was absent when the
  app was inspected afterward. Investigate confirmation lifetime/remount behavior;
  file delivery passed, durable success feedback did not receive a pass.
- One injected Android hardware Enter produced two CRLFs, while Gboard's actual
  Done button produced one. Keep hardware-key handling as a separate compatibility
  follow-up; do not conflate the two input paths.
- The administrator-window warning/recovery check remains unverified. An existing
  RTSS window was opened without changing its settings, but subsequent laptop-mode
  controls did not respond reliably to automated taps. Android Back recovered the
  Console. Physical-touch confirmation is needed before attributing that behavior
  to the app rather than the control harness. RTSS/Afterburner were minimized again;
  the agent remained at normal privileges.
- iPhone testing is explicitly deferred by the owner. Caret-in-the-middle editing,
  two-finger scrolling, cancellation/retry and backgrounding during an active
  transfer were not validated in this pass.

Raw device screenshots, exact saved test text, machine addresses, license/pairing
data and QA helpers remain private. Only this sanitized result is committed. No
main merge, release, manifest change, store submission or email send was performed.

## Android follow-up: warning, editing and upload lifecycle (2026-10-28)

Further checks on the same Razr build and physical Windows candidate resolved
several of the preceding open observations without changing runtime code:

- In the standard portrait Pad, focusing the existing RTSS administrator window
  caused the explicit administrator-app-blocks-input warning to appear. Switching
  Windows focus back to normal Notepad cleared the warning and phone typing
  resumed without reconnecting or re-pairing. The agent stayed non-elevated with
  UIAccess disabled. No RTSS/Afterburner settings were changed, and both windows
  were minimized again afterward. This does not validate the laptop-mode warning.
- Moving the phone compose caret into `abcd`, inserting `X`, then deleting it
  produced `abXcd` and then `abcd` on Windows, preserving the suffix. The final
  saved disposable document was read back to verify the result.
- Canceling the native picker returned to the idle upload card without an error;
  reopening it and sending another file worked.
- Timed screenshots of a fresh 8 MiB upload captured the sending state and then
  the success receipt at 8 and 15 seconds after selection. A later observation
  showed the neutral prompt. The source deliberately clears success after 12
  seconds from completion; the previously absent receipt is therefore explained
  by its intended lifetime, not demonstrated transfer failure. The destination
  size and hash matched again.
- Another uniquely named 8 MiB file was visibly still sending just before the
  phone went Home. Its complete destination and matching SHA-256 were verified
  while Couchside remained backgrounded, before reopening the app. Returning to
  Couchside retained the green locked connection. This is a brief background
  transfer check, not a long-duration or process-termination guarantee.

The injected hardware-Enter duplication, laptop-mode interaction/warning checks,
and two-finger scrolling remain open. iPhone testing is still deferred. The Steam
Machine was not reachable during this pass, so its prerelease-agent live checks
are still pending. No new binaries, release, merge, manifest or email was issued.

## Companion SteamOS compatibility smoke (2026-10-28)

The Steam Machine became reachable later in the same QA session. This is a
separate Linux compatibility check with Razr Direct 2.9.79(48), not additional
Windows installer certification:

- The existing saved pairing reconnected with the encrypted-connection indicator.
  The installed Linux agent reports 2.9.134. Its source differs from the app
  candidate in separate Player functionality; it was inspected and left intact.
  These results therefore do not certify an exact frozen release-agent binary.
- Phone right/left swipe input moved Steam's selected tile in both directions,
  verified through fresh screen frames rather than command responses alone.
- Native 60-byte and 8 MiB uploads arrived with matching sizes and SHA-256 hashes.
  The larger upload completed while the app remained backgrounded, before resume;
  returning retained the saved secure connection.
- With four raw TLS connections left without a handshake, three independent
  certificate-verified HTTPS status requests returned 200 in 16–21 ms. All test
  sockets were closed afterward. This is a bounded responsiveness smoke test,
  not a load-test or denial-of-service guarantee.
- One suspend/wake cycle was initiated through the native phone UI. The box went
  offline, the app showed wake progress, the connection indicator was online by
  the 10-second capture, and the 20-second capture showed “Box is awake.” The
  system journal confirmed suspend/resume; fresh screen capture and verified
  HTTPS worked afterward. The machine was left awake.
- The owner confirmed that the laptop-mode X exits correctly by physical touch.
  Automated laptop-mode taps remain unreliable, so they are not treated as proof
  of a broken exit control or a complete laptop-mode interaction pass.

No agent replacement, app install, pairing reset, main merge, release, public
manifest change or email send occurred. iPhone validation remains deferred.

## Physical iPhone input and warning checks (2026-10-29)

The owner made the iPhone available, superseding the earlier device-test deferral.
The installed native app was verified as 2.9.79(273); this check does not assert
that the installed binary was delivered through TestFlight.

- The existing Windows pairing reconnected with its green lock. The app retained
  three saved boxes and its prior unlock state, without reinstalling or re-pairing.
- Mixed-case text, punctuation, numbers, backspace and Return reached a disposable
  Notepad document. Saved-file readback confirmed exactly one CRLF for the tested
  Mirroring keyboard Return path. This does not cover the on-screen iOS keyboard
  or resolve the separate Android injected-hardware-Enter observation.
- Moving the compose caret into `abcd`, inserting and deleting `X`, preserved
  the suffix on Windows. The saved document confirmed the final text.
- The phone right-click opened Notepad's context menu. Phone Alt-Tab returned
  from Steam to Notepad without losing the saved connection. Calibrated mouse
  movement and two-finger scrolling were not isolated sufficiently for a pass.
- Focusing the existing RTSS administrator window displayed the explicit
  administrator-app-blocks-input warning. Returning focus to normal Notepad
  cleared it, and new phone typing arrived without reconnecting or re-pairing.
  The agent stayed non-elevated with UIAccess disabled. RTSS/Afterburner settings
  were not changed, and both windows were minimized again.

Native iPhone uploads, active-transfer background/resume, and fresh iPhone checks
against the SteamOS companion remain pending. Mirroring's automated scrolling
did not move the Console; the owner scrolled to the upload card manually. This
control-harness limitation is not treated as an app crash or transfer failure.

Only sanitized QA documentation is published. Raw inventories, exact test text,
addresses and private evidence remain local. No runtime changes, release, main
merge, public manifest change, store submission or email send occurred.
