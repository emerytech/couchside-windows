# Windows combined preview — not released

Frozen Windows source: 5c96b4d. Build installer workflow 40523441131 completed
successfully on windows-latest. Its couchsided-win.py, qr.py, build.ps1 and
install.ps1 match the monorepo combined candidate 5f4dfb1 byte-for-byte.

Downloaded artifacts:
- CouchsideSetup.exe SHA-256 68eecd3015edfa88e709547c962792d0daafdc7fb47b2cfdc00b75d6386bd646
- couchside-agent.exe SHA-256 dba4c5fbe53db1dad39cca4d6023c8733b8472b0313d2bd0f17ab8d4abd58674
Both are PE GUI subsystem 2. Installer has no Authenticode certificate table;
this is an unsigned test artifact, not a production signing claim.

Prior clean/upgrade testing preserved token, configuration, TLS identity and ACLs.
Still required: post-reboot interactive sign-in/startup, real phone controls
and upload checks on final builds, installer wizard/UAC and first-ever driver
install as applicable. Keep Limited startup privileges and warning behavior.

No production merge/tag/download publication is authorized.
