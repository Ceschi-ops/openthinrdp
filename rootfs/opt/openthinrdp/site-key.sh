#!/bin/bash
# The public key of the site for the software updates (/etc/openthinrdp/update-key.asc), sent by the manager over SSH
# (Vault > Send to the devices): "install" reads it from standard input. Only an OpenPGP public key is accepted (a
# secret key never belongs here); the change is written to the event log. SSH as otradmin is root already: this
# gives nothing more, it only checks what arrives and says what changed.
#   site-key.sh install < update-key.asc
#   site-key.sh show                       the fingerprint of the key in place, or "none"
. /opt/openthinrdp/lib/common.sh
K=$OTR_ETC/update-key.asc
case "$1" in
  show) key_fingerprint "$K" || echo none ;;
  install)
    [ "$(id -u)" = 0 ] || { echo "ERROR=run as root"; exit 1; }
    T=$(mktemp); trap 'rm -f "$T"' EXIT
    head -c 65536 > "$T"
    grep -q -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$T" || { echo "ERROR=not an armored OpenPGP public key"; exit 1; }
    grep -q -- 'PRIVATE KEY' "$T" && { echo "ERROR=a secret key: never on a device"; exit 1; }
    NEW=$(key_fingerprint "$T") || { echo "ERROR=no version 4 public key in it"; exit 1; }
    OLD=$(key_fingerprint "$K" 2>/dev/null || echo none)
    if [ "$NEW" = "$OLD" ] && cmp -s "$T" "$K"; then echo "OK=$NEW (already in place)"; exit 0; fi
    install -m644 "$T" "$K.new" && mv -f "$K.new" "$K" || { echo "ERROR=cannot write $K"; exit 1; }
    ev "site key of the updates: $NEW (was $OLD), sent by the manager"
    echo "OK=$NEW" ;;
  *) echo "usage: $0 install < update-key.asc | show"; exit 2 ;;
esac
