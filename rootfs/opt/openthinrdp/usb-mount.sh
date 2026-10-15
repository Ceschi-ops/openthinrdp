#!/bin/bash
# Mount USB sticks and disks in /media/<label> (started by udev, 70-openthinrdp-usb-mount.rules) with
# USB_MODE=disks, and with auto when the device is only storage (lib/usb.sh): FreeRDP (/drive:hotplug,*) then
# shows them in Windows, also when plugged in during a session. In "all" mode, and for a device that goes whole
# with auto, the storage goes to Windows with the device and nothing is mounted here.
. /opt/openthinrdp/lib/common.sh
. /opt/openthinrdp/lib/usb.sh
DEV=/dev/$1
grep -q "^$DEV " /proc/mounts && exit 0      # both "add" and "change" arrive: no double mount
TYPE=$(blkid -o value -s TYPE "$DEV" 2>/dev/null)
[ -n "$TYPE" ] || exit 0
usb_mount_here "$(usb_of_block "$1")" || exit 0
# devices passed whole to Windows (USB_REDIRECT): Windows uses them, not mounted here
ID=$(udevadm info -q property -n "$DEV" 2>/dev/null | awk -F= '/^ID_VENDOR_ID=/{v=$2} /^ID_MODEL_ID=/{m=$2} END{print tolower(v":"m)}')
for u in $(cfg USB_REDIRECT); do [ "$u" = "$ID" ] && exit 0; done
LABEL=$(blkid -o value -s LABEL "$DEV" 2>/dev/null | tr -c 'A-Za-z0-9._-' '_' | sed 's/_*$//')
[ -n "$LABEL" ] || LABEL="USB-$1"
MP="/media/$LABEL"
grep -q " $MP " /proc/mounts && MP="/media/$LABEL-$1"
KU=$(id -u "$OTR_KIOSK_USER" 2>/dev/null || echo 1000); KG=$(id -g "$OTR_KIOSK_USER" 2>/dev/null || echo 1000)
case "$TYPE" in
  vfat|exfat) OPT="uid=$KU,gid=$KG,umask=022,utf8,flush" ;;
  ntfs|ntfs3) TYPE=ntfs3; OPT="uid=$KU,gid=$KG,umask=022" ;;
  *)          OPT="" ;;
esac
mkdir -p "$MP"
# systemd-mount: the mount lives outside udev and goes away by itself when the stick is removed
systemd-mount --no-block --collect -t "$TYPE" ${OPT:+-o "$OPT"} "$DEV" "$MP"
ev "USB storage $1 ($TYPE, $LABEL) mounted on $MP"
