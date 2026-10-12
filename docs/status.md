# Status: what you can deploy today

OpenThinRDP is numbered 0.1, but it is not a prototype: it runs a company's whole thin client fleet every day.
This page says what is used in production, what is available but not exercised by that fleet, and what does
not exist yet, so you know what to test before rolling it out.

## The production fleet

- **14 Dell OptiPlex 3000 Thin Clients** (BIOS 1.19 to 1.37), wired, in offices, at the tills, in a laboratory
  and at weighing stations.
- **Windows 11 VDI on Hyper-V**: personal desktops behind two RD Connection Brokers (DNS round robin), plus a
  handful of session hosts.
- Every device was **converted in place** from the system it ran before, by an update package, with its settings
  carried over; none was reinstalled by hand.
- Updates reach them from the **management folder**, signed, installed in the background during sessions and
  applied when the session is over.

## In production every day

| Area | What |
|---|---|
| Sign-in | Kiosk sign-in screen, default user, two brokers with fallback, load balance info for VDI collections |
| Transport | **RDP over UDP** (`TRANSPORT=auto`) with fallback to TCP; reconnection after network drops |
| USB | Whole-device redirection of signature keys and other special devices, also plugged in during the session |
| Meetings | Webcams through the RDP camera channel, microphones and speakers through the RDP audio channels |
| Smart cards | Readers through the smart card channel (pcscd) |
| Touch | Touch screens at the tills, as real touch in Windows |
| Management | Status and events of every device, central settings (common and per device), logo and background, Windows manager |
| Updates | Signed packages from the management folder; Debian security updates by themselves |
| Power | Shutdown at the end of the session, Wake-on-LAN (also from the BIOS) |

## Available, not exercised by that fleet

These work in our tests (QEMU/KVM at every release, the system tests in `tests/`, a test device), but the
production fleet does not use them, so test them in your environment first:

- **ISO installation** on new hardware: live system and automatic installation, Secure Boot. Tested in QEMU/KVM
  with Secure Boot at every release; the fleet itself was converted in place, not installed from the ISO.
- Updates straight from GitHub releases (`UPDATE_FROM=github`).
- Wi-Fi and static addressing.
- Web kiosk and web button (Chromium with policies).
- Power-on schedule (RTC wake alarm, needs firmware support).
- `RDP_CERT=verify` with your own certificate authority.

## Not available yet

- Citrix, VMware/Omnissa Horizon or any protocol other than RDP.
- ARM devices.
- VPN (WireGuard, OpenVPN), RD Gateway, 802.1X, network boot (PXE).
- Disk encryption, signed central configuration.

Tell us what you need first in the [discussions](https://github.com/OpenThinRdp/openthinrdp/discussions).

## Tested hardware

| Device | Status |
|---|---|
| Dell OptiPlex 3000 Thin Client | production (14 devices) |
| QEMU/KVM, UEFI with Secure Boot | tested at every release |

Other x86-64 PCs and thin clients with UEFI should work: reports in the
[discussions](https://github.com/OpenThinRdp/openthinrdp/discussions) are very welcome.

## When something goes wrong

- **A device cannot reach the management folder.** It keeps the last settings it read (the last good
  configuration) and keeps working. The ℹ button of the sign-in screen shows the network and the reachability
  of the folder and of the brokers; the settings dialog (PIN) fixes the folder, user or password on the device.
- **An update is interrupted.** A package is checked (signature, hash, syntax of every script) before anything
  is touched; Shut down waits for a running install. If the power goes in the middle, the device installs the
  same package again at its next check, because its version is still the old one.
- **Going back.** Devices never install an older version. To go back, publish the older package again under a
  higher version number, or reinstall the device from the ISO: its settings come back from the management folder.
- **A device is stolen.** Rotate the management folder password (`MGMT_PASSWORD` in the central settings) and,
  if it had one, the password of the session user. See [security.md](security.md).
