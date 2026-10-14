# The secrets of the device: the password of the management folder account, the Wi-Fi key, the SSH host keys.
# Source it after common.sh: . /opt/openthinrdp/lib/secrets.sh   (root only)
# With a TPM 2.0 they are kept encrypted with a key that never leaves the TPM (systemd-creds, --with-key=tpm2,
# no PCRs: a firmware update or a Secure Boot change does not lose them) in $OTR_SEALED, and decrypted at every
# start into $OTR_SECRETS, in memory (secrets.sh, before the network and SSH). A disk or eMMC taken out of the
# device gives nothing. Without a TPM they stay in root-only files where they always were.
OTR_SEALED=$OTR_ETC/sealed
OTR_SECRETS=/run/openthinrdp/secrets
# name -> where the file lives without a TPM
declare -A OTR_SECRET_FILES=(
  [smb.cred]=$OTR_ETC/smb.cred
  [wifi.conf]=/etc/wpa_supplicant/openthinrdp-wifi.conf
  [ssh_host_ed25519_key]=/etc/ssh/ssh_host_ed25519_key
  [ssh_host_ecdsa_key]=/etc/ssh/ssh_host_ecdsa_key
  [ssh_host_rsa_key]=/etc/ssh/ssh_host_rsa_key
)

# a TPM 2.0 that systemd can use: firmware, driver, device and the tss2 libraries ("partial" = exit 16 = no)
secret_tpm(){ command -v systemd-creds >/dev/null && systemd-analyze has-tpm2 >/dev/null 2>&1; }
secret_sealed(){ [ -s "$OTR_SEALED/$1.cred" ]; }

# secret_path NAME: the file to read the secret from (the copy in memory, or the plain file). It may not exist.
secret_path(){
  if secret_sealed "$1"; then
    [ -s "$OTR_SECRETS/$1" ] || secret_unseal "$1"
    echo "$OTR_SECRETS/$1"
  else echo "${OTR_SECRET_FILES[$1]}"; fi
}

# secret_unseal NAME: decrypt into memory. 1 = the TPM does not give it back (another TPM, TPM cleared)
secret_unseal(){
  install -d -m 700 "$OTR_SECRETS"
  ( umask 077; systemd-creds decrypt --name="$1" "$OTR_SEALED/$1.cred" "$OTR_SECRETS/$1.new" >/dev/null 2>&1 ) || {
    rm -f "$OTR_SECRETS/$1.new"; return 1; }
  mv -f "$OTR_SECRETS/$1.new" "$OTR_SECRETS/$1"
}

# secret_store NAME FILE: FILE (new content) becomes the secret; FILE is consumed. Into the TPM when there is one
# (the plain file, if any, is removed), otherwise the plain file, root 600.
secret_store(){
  local n=$1 f=$2 plain=${OTR_SECRET_FILES[$1]}
  if secret_tpm || secret_sealed "$n"; then
    install -d -m 700 "$OTR_SEALED" "$OTR_SECRETS"
    if systemd-creds encrypt --with-key=tpm2 --tpm2-pcrs= --name="$n" "$f" "$OTR_SEALED/$n.cred.new" >/dev/null 2>&1; then
      chmod 600 "$OTR_SEALED/$n.cred.new"; mv -f "$OTR_SEALED/$n.cred.new" "$OTR_SEALED/$n.cred"
      install -m 600 "$f" "$OTR_SECRETS/$n"; rm -f "$f" "$plain"
      return 0
    fi
    rm -f "$OTR_SEALED/$n.cred.new"
    ev "secret $n: the TPM refused it, kept in a root-only file"
  fi
  install -d "$(dirname "$plain")"; chmod 600 "$f"; mv -f "$f" "$plain"; rm -f "$OTR_SEALED/$n.cred"
}

# secret_mode: what the status file reports
secret_mode(){
  local n
  for n in "${!OTR_SECRET_FILES[@]}"; do secret_sealed "$n" && { echo tpm; return; }; done
  if secret_tpm; then echo "tpm (nothing stored yet)"; else echo "file (no TPM)"; fi
}
