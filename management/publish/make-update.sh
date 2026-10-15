#!/bin/bash
# Build and sign an update package for the thin clients, and publish it in the management folder.
#   make-update.sh -v <version> [-k <gpg key id>] [-f] [-d <debs folder>] [-s <site folder>] [-o <management folder>]
#     -v  version, must grow (e.g. 0.1.1): devices never install an older one
#     -k  OpenPGP key that signs, in the gpg of this machine: the project key for a release (its public half is
#         rootfs/opt/openthinrdp/keys/openthinrdp-release.asc), or your own key for your own packages (its public
#         half is update-key.asc in the site folder of your image).
#         Without -k nothing is signed here: out/update-<version>/LATEST.txt is signed by the manager with the key
#         kept in its vault (OpenThinRDP-Manager.cmd -Sign <path>\LATEST.txt, or Vault > Sign an update), so the
#         signing key never sits on the build machine.
#     -f  ship the FreeRDP with UDP of image/freerdp/freerdp.conf (out/freerdp/<commit>, made by image/build.sh
#         or image/freerdp/build-debs.sh): devices get it when it is newer than theirs
#     -d  other .deb files to ship (e.g. your own FreeRDP build): installed only when newer
#     -s  site folder to ship too (site.conf, logos, ca/, update-key.asc, authorized_keys). Never in a release
#     -o  management folder (mounted, e.g. /mnt/thinclients): the package goes to <folder>/updates.
#         Without -o the result stays in out/update-<version>/.
# A release (UPDATE_FROM=github) = the 3 files of out/update-<version>/ attached to a GitHub release that is not
# a pre-release, signed with the project key:
#   make-update.sh -v 0.1.1 -k <project key> -f      (or without -k, then -Sign in the manager)
#   gh release create v0.1.1 out/update-0.1.1/* --title "OpenThinRDP 0.1.1" --notes "..."
# Needs: bash, tar, gzip, sha256sum, gpg (Linux, WSL, or Git Bash with Gpg4win).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
V=""; KEY=""; DEBS=""; SITE=""; DEST=""; FRDP=""
while getopts "v:k:fd:s:o:" o; do
  case $o in v) V=$OPTARG ;; k) KEY=$OPTARG ;; f) FRDP=1 ;; d) DEBS=$OPTARG ;; s) SITE=$OPTARG ;; o) DEST=$OPTARG ;; *) exit 2 ;; esac
done
if [ -n "$FRDP" ]; then
  . "$ROOT/image/freerdp/freerdp.conf"
  FRDP="$ROOT/out/freerdp/$FREERDP_COMMIT"
  [ -f "$FRDP/SHA256SUMS" ] || { echo "no FreeRDP packages in $FRDP: run image/freerdp/build-debs.sh (or image/build.sh) first"; exit 2; }
  (cd "$FRDP" && sha256sum -c --quiet SHA256SUMS) || { echo "FreeRDP packages in $FRDP do not match their SHA256SUMS"; exit 2; }
fi
[[ $V =~ ^[0-9A-Za-z._-]+$ ]] || { echo "version missing or not valid (-v)"; exit 2; }
# without a key here the package cannot go to a management folder: it would be published unsigned
[ -n "$KEY" ] || [ -z "$DEST" ] || { echo "-o needs -k: without -k, sign out/update-$V/LATEST.txt in the manager, then copy the 3 files"; exit 2; }
for f in "$ROOT"/rootfs/opt/openthinrdp/*.sh "$ROOT"/rootfs/opt/openthinrdp/lib/*.sh; do bash -n "$f"; done

OUT="$ROOT/out/update-$V"; STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
rm -rf "$OUT"; mkdir -p "$OUT"
cp -a "$ROOT/rootfs" "$STAGE/rootfs"
cp "$HERE/install.sh" "$STAGE/"; echo "$V" > "$STAGE/VERSION"
cp "$ROOT/image/lb/packages.list" "$STAGE/packages.list"
# the project's pictures: install.sh puts them only where a device still shows an older project picture
mkdir -p "$STAGE/project-branding"; cp "$ROOT"/image/branding/logo.png "$ROOT"/image/branding/splash.png "$STAGE/project-branding/"
if [ -n "$DEBS" ]; then mkdir -p "$STAGE/debs"; cp "$DEBS"/*.deb "$STAGE/debs/"; fi
if [ -n "$FRDP" ]; then mkdir -p "$STAGE/debs"; cp "$FRDP"/*.deb "$STAGE/debs/"; fi
if [ -n "$SITE" ]; then
  mkdir -p "$STAGE/site"
  for f in site.conf logo.png splash.png update-key.asc authorized_keys; do [ -f "$SITE/$f" ] && cp "$SITE/$f" "$STAGE/site/"; done
  if ls "$SITE"/ca/*.crt >/dev/null 2>&1; then mkdir -p "$STAGE/site/ca"; cp "$SITE"/ca/*.crt "$STAGE/site/ca/"; fi
fi
# Unix line endings and modes, whatever the checkout did
find "$STAGE" -type f \( -name '*.sh' -o -name '*.conf' -o -name '*.rules' -o -name '*.service' -o -name '*.timer' \
  -o -name '*.path' -o -name '*.list' -o -name '*.xml' -o -name 'openthinrdp' \) -exec sed -i 's/\r$//' {} +
# modes of the system, whatever the umask or checkout: install.sh copies them onto /, /etc, /opt... (a
# group-writable /etc makes sshd refuse every key)
chmod -R u=rwX,go=rX "$STAGE"
chmod 755 "$STAGE/install.sh" "$STAGE"/rootfs/opt/openthinrdp/*.sh
F="openthinrdp-update-$V.tar.gz"
tar -czf "$OUT/$F" --owner=0 --group=0 -C "$STAGE" .
H=$(sha256sum "$OUT/$F" | cut -c1-64)
printf 'version=%s\nfile=%s\nsha256=%s\n' "$V" "$F" "$H" > "$OUT/LATEST.txt"
if [ -z "$KEY" ]; then
  echo "package ready in $OUT, NOT signed yet: OpenThinRDP-Manager.cmd -Sign <this folder>\\LATEST.txt (key in the vault)"
  exit 0
fi
gpg --batch --yes --local-user "$KEY" --armor --detach-sign -o "$OUT/LATEST.txt.sig" "$OUT/LATEST.txt"
gpg --batch --verify "$OUT/LATEST.txt.sig" "$OUT/LATEST.txt"
echo "package ready in $OUT"
[ -z "$DEST" ] && exit 0
mkdir -p "$DEST/updates"
# package first, then signature and index: a device never sees an index that points to a missing file
cp "$OUT/$F" "$DEST/updates/"
[ "$(sha256sum "$DEST/updates/$F" | cut -c1-64)" = "$H" ] || { echo "the copy in $DEST/updates is not intact"; exit 1; }
cp "$OUT/LATEST.txt.sig" "$DEST/updates/"; cp "$OUT/LATEST.txt" "$DEST/updates/"
# keep the last 3 packages
ls -t "$DEST"/updates/openthinrdp-update-*.tar.gz | tail -n +4 | xargs -r rm -f
echo "PUBLISHED $V in $DEST/updates"
