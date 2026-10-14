#!/bin/bash
# At every start (openthinrdp-secrets.service, before the network and SSH): the secrets of the device out of the
# TPM into memory, and, with a TPM, the plain files of a device set up before into the TPM (lib/secrets.sh).
. /opt/openthinrdp/lib/common.sh
. "$OTR/lib/secrets.sh"
mkdir -p "$OTR_LOG"; touch "$OTR_EVENTS"
install -d -m 700 "$OTR_SECRETS"
TPM=0; secret_tpm && TPM=1
moved=""; lost=""
for n in "${!OTR_SECRET_FILES[@]}"; do
  p=${OTR_SECRET_FILES[$n]}
  if secret_sealed "$n"; then
    # a plain copy next to the one in the TPM (e.g. host keys created again by an openssh-server upgrade) is never
    # used: removed, so no secret stays readable on the disk
    if secret_unseal "$n"; then [ -e "$p" ] && rm -f "$p"; else lost="$lost $n"; fi
  elif [ $TPM = 1 ] && [ -s "$p" ]; then
    t=$(mktemp); cp -p "$p" "$t" && secret_store "$n" "$t" && secret_sealed "$n" && moved="$moved $n"; rm -f "$t"
  fi
done
[ -n "$moved" ] && ev "secrets moved into the TPM:$moved (plain files deleted; on flash memory old blocks may survive until overwritten)"
# not readable any more (TPM cleared or replaced, disk moved to another device): set aside, never retried at every
# start. SSH host keys are created again by apply.sh; the folder password and the Wi-Fi key must be set again.
if [ -n "$lost" ]; then
  for n in $lost; do mv -f "$OTR_SEALED/$n.cred" "$OTR_SEALED/$n.cred.unreadable"; done
  ev "secrets NOT readable from the TPM:$lost (TPM cleared or replaced, or the disk moved to another device): set them again"
fi
# sshd starts after this service: it must already know where the host keys are (in memory when in the TPM)
secret_sshd_hostkeys
exit 0
