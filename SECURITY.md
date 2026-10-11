# Security policy

Please **do not** report security problems in public issues.

Use GitHub's private reporting instead: on the repository page, **Security** → **Report a vulnerability**.
Describe what an attacker can do, on which version, and how to reproduce it. You will get an answer as soon as
possible; fixes are released as a new version and announced in a security advisory, crediting you if you wish.

Supported versions: the latest release only.

What OpenThinRDP protects and its known limits are described in [docs/security.md](docs/security.md).

## Release signing key

Releases (the software updates that devices install with `UPDATE_FROM=github` or from a management folder) are
signed with this OpenPGP key, built into the image as `/opt/openthinrdp/keys/openthinrdp-release.asc`:

```
OpenThinRDP releases <203820048+Ceschi-ops@users.noreply.github.com>
ed25519, fingerprint 8552 734B 5C1B 67D7 C576  F1AB 79B2 3AE6 1CD4 F6AF
```

A device installs nothing whose `LATEST.txt` is not signed by it (or by your own key, for your own packages
in your management folder). If the key ever has to be replaced, the new one comes with an update signed by
the old one, and the old one is revoked here.
