# OpenCode update channel

The public project ID lives in `assets/update-project.txt`. The app and publisher
read that same file. The current channel is:
https://forge.boqsc.eu/~/fg_698edca9f4704bcc/

The publishing credential is retained in
`%APPDATA%/Aurora OpenCode/forge-publisher.json`, outside the repository and EXE.
Normal rebuilds upload a changed EXE and release.json, then download the public
files to verify delivery. Builds using an installed Windows C runtime are
allowed; required DLL names appear in release.json. These builds require that
runtime on the recipient's machine.

Commit and push the build source to the branch selected in
`assets/maintainer-source-branch.txt` before the delivery rebuild. DUB records a
fingerprint before compilation and verifies it after icon embedding. The publisher
requires that record to match the executable and current clean source, verifies
the exact commit is the public channel branch tip, and includes the source commit,
branch and fingerprint in `release.json`. A changed source tree or binary requires
a new rebuild; the publisher cannot certify a manually replaced executable.

For an explicit publish with a failing exit code on any problem:

```powershell
python tools/publish-forge.py --required
```

Local verification rebuilds set `FORGE_PUBLISH_SKIP=1` and remain local. Explicit
publication must run without that flag. A successful build alone does not prove
publication: look for `Published and publicly verified` or
`Forge release unchanged; public download verified`.

`opencode-update.yml` builds and publishes on relevant maintainer-source-branch pushes, v-tags,
and manual dispatch. Set the repository Actions secret `OPENCODE_FORGE_PUBLISHER_KEY` to
the saved local credential's `key` field to enable CI publication. This secret is
not automatically transferred from a developer's Windows profile. Missing or
wrong credentials fail that workflow. Forks do not publish to this channel.
The new secret was configured and its presence verified on October 10, 2026.
Existing secrets were preserved. Keep the workflow's push branch aligned with
`maintainer-source-branch.txt` when moving the update channel. Publication from
other refs fails the source-commit check.

To create a different project, `python tools/configure-forge.py --new` issues a
fresh key and persists it before updating the public project ID. It refuses to
replace an existing local publisher config. Creating another channel requires a
new app build: previous installations retain their embedded channel and need a
manual upgrade unless the old channel can publish a migration build.

Keep a private backup of the publisher config with your Windows profile. Its
key must never be committed, embedded in the application, or pasted into chat.
