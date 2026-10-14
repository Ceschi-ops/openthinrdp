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
    secret_unseal "$n" || lost="$lost $n"
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
exit 0
