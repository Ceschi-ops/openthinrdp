# USB devices by what they are made of (their interfaces in sysfs). Source it: . /opt/openthinrdp/lib/usb.sh
# Used by USB_MODE=auto: a device that is only storage (a stick, a card reader, a disk) stays on the thin client
# and appears in Windows as a drive; a device that has storage AND something else (an instrument with a serial
# port, a signature key with its own driver...) goes to Windows whole, because only its Windows driver can use it.
# USB_SYS = where the USB devices are (the tests use a tree of their own).
USB_SYS=${USB_SYS:-/sys/bus/usb/devices}

# interface classes of a device (its sysfs folder): sorted, once each, space separated ("08 ", "02 0a 08 ")
usb_classes(){
  local i
  for i in "$1"/*:*; do [ -f "$i/bInterfaceClass" ] && cat "$i/bInterfaceClass"; done | sort -u | tr '\n' ' '
}
# only storage: every interface is mass storage (class 08)
usb_storage_only(){ [ "$(usb_classes "$1")" = "08 " ]; }
# the USB device a block device (sda, sda1) belongs to: its sysfs folder, or nothing
usb_of_block(){
  local d
  d=$(readlink -f "/sys/class/block/$1" 2>/dev/null) || return 1
  while [ -n "$d" ] && [ "$d" != / ]; do
    [ -f "$d/idVendor" ] && { echo "$d"; return 0; }
    d=$(dirname "$d")
  done
  return 1
}
# storage of this USB device stays on the thin client and is mounted as a drive: always with USB_MODE=disks, never
# with all (Windows gets the whole device), with auto when the device is only storage or never goes whole anyway
# (a smart card reader with storage: the reader goes through /smartcard, its storage as a drive)
usb_mount_here(){
  case "$(cfg USB_MODE)" in
    disks) return 0 ;;
    auto) [ -n "$1" ] || return 1; usb_storage_only "$1" && return 0; case " $(usb_classes "$1")" in *" 0b "*) return 0 ;; esac; return 1 ;;
    *) return 1 ;;
  esac
}
