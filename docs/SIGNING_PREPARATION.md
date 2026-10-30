# Windows signing preparation (test candidate, not a release)

Candidate: `0.4.15-rc1-win`. The public `0.4.14-win` assets are unchanged.
The canonical agent/build/install sources must land in the product monorepo before
this repository's mirror is integrated. Sync now proposes a PR from one upstream
commit instead of directly changing main. Checks on bot-created PRs require a
separate explicitly dispatched CI run on the reviewed head.

## Behavior

- Update checks and in-app installation are separate, default-off owner choices.
  Checking is read-only. Both consult this Windows repository's releases.
- Applying refuses source, unsigned and prerelease builds. A signed stable agent
  requires a newer stable release, exact repository/tag asset URLs, a bounded
  checksum download, matching SHA-256, valid timestamped SignPath Foundation
  Authenticode, and matching product/version. Redirects are checked before following.
- No request-supplied URL, version, installer arguments, or shell command is used.
  Concurrent installer launches are refused. Verification failures remove downloads.
- Existing settings and pairing are preserved. The wizard's optional tasks start
  unchecked. `-EnableUpdateCheck` / `-DisableUpdateCheck` express explicit consent;
  omission preserves it on scripted upgrades. Silent wizard upgrades preserve prior
  choices; an interactive unchecked update-check task explicitly disables checking.
- Build dependencies and controller DLL are hash checked. Pip reinstalls from the
  lock to verify bytes even in an already-populated environment. Inno Setup's
  installer and compiler are checked by hash; the actual compiler PE version is
  `0.0.0.0`, so it is not used as version evidence.
- The signed-release workflow remains dormant until the owner separately enables
  `SIGNPATH_RELEASE_ENABLED` and configures an approved SignPath project and approval
  environment. This change does not configure either service. No signing keys are
  added to CI. Current runner image and Python patch version are not fully pinned.

## Verification

On Windows 11 with Python 3.12, an offline-dependency build produced both unsigned
executables with Couchside product metadata / numeric version `0.4.15.0`.
The 19-case updater suite and 8-case HTTPS suite passed on Windows and macOS. The real
PowerShell 5.1 consent writer passed omission, enable, preservation, disable,
unknown-field preservation and temporary-file cleanup checks. Deliberately missing
or incorrect dependency locks and a corrupt DLL stopped the build.

The VM installer upgrade returned success and preserved the pairing token,
configuration and TLS identity. The startup task remained Interactive / Limited.
Opted-in update checking survived a second silent upgrade. The app's web preview
shows a disabled-check message after a manual check, and TypeScript checks passed.
Uninstall removed the agent, startup task and firewall rules; reinstall preserved
pairing/config/TLS. HTTP 401 and preview 409 refusal were confirmed against the
installed executable with the update worker remaining idle. These checks do not
certify physical phone/controller behavior or a fresh OS install.

## Still required before enabling signed self-updates

- SignPath eligibility, project restrictions and exact actual signer identity;
  verify signed agent and installer on Windows. Foundation certificates may be
  shared: repository checks and metadata are not a project-specific signing key.
- Two approved signed stable versions for a real N → N+1 update, including UAC,
  denial, restart and failure recovery. Mock verification is not this acceptance test.
- Fresh-OS installation without Python, interactive wizard/SmartScreen/UAC,
  and optional driver install/fallback checks.
- Repeat cleanup with genuine signed artifacts. Independent supervision already
  passed five Windows process tests and a real unsigned-installer test after the
  initiating process was terminated. Leftovers are never resumed or executed.
- Confirm signed workflow execution and artifact layout after SignPath approval.
  Unsigned CI builds are separate test artifacts and do not certify signing.

No licenses, public manifests, website policy or repository settings are changed.
