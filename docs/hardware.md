# Hardware

## Tested

| Device | Notes |
|---|---|
| Dell OptiPlex 3000 Thin Client (Intel Pentium Silver/Celeron, eMMC, Realtek NIC) | the reference device: boot to sign-in form in about 6 s after the firmware |

Any x86-64 PC with UEFI should work. Reports for other devices are welcome (open an issue with the model,
what works and what does not).

## Firmware settings (Dell)

- **Wake-on-LAN**: enable "Wake on LAN" and **disable "Deep Sleep Control"**. With deep sleep in S4/S5 the
  network card is off and the magic packet never arrives. The same setting blocks the RTC alarm used by
  `POWER_ON_TIME`.
- **USB boot** must be enabled to install from a stick (Integrated Devices).
- On Linux the settings can be changed without entering the setup screen, through `dell-wmi-sysman`
  (`/sys/class/firmware-attributes/dell-wmi-sysman/`), with the BIOS admin password if one is set.

## Monitors

- A monitor switched on after the thin client (or a slow HDMI/DisplayPort link) leaves X without an output:
  the kiosk checks every 2 s and enables it.
- Monitors with a built-in USB hub may expose a "Hub Controller" device: it is kept local.
- Touch monitors stay local and their touches go to Windows as real touch input (`+multitouch`).

## USB devices seen in the field

- Webcams with microphone (UVC + audio): passed whole; their microphone becomes the Windows default.
- Signature keys with smart card reader + storage: the reader goes through the smart card channel, the
  storage as a whole device.
- Composite devices that restart in another mode once they see a PC (e.g. tachograph download keys): passed
  with `/usb:auto`, so they are passed again after re-enumeration. Devices plugged in during the session are
  passed only with a FreeRDP that has the `filter:` option of the USB channel (merged upstream after 3.32.1);
  with older versions plug them in before signing in, or list them in `USB_REDIRECT`.
- USB network adapters are never passed (the device would lose its own network).
