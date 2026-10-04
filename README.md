# Wi-Fi Hotspot for Linux (hostapd GUI)

Share your laptop's Wi-Fi **while staying connected to that same Wi-Fi**, like Windows' Mobile Hotspot.
GNOME's built-in hotspot switch drops your Wi-Fi connection; this uses a second virtual access-point
interface on the same radio instead.

**v1.0** — written and tested on one laptop (Ubuntu 26.04, GNOME 50). Expect rough edges on other hardware.

## Features
- Network name, password, WPA2 / WPA2+WPA3 / WPA3, max devices, total download limit
- Per-device data used, live speed, per-device download/upload limit
- Block devices, or allow only approved devices (by MAC)
- Isolate devices from each other, auto-off when idle, data cap per session
- Join/leave desktop notifications
- Password and QR code to connect (asks for your system password)
- **GNOME Quick Settings toggle**: start/stop from the top-right system menu — no extra extension needed

## Requirements
- Debian/Ubuntu-family Linux, GNOME (GTK4 + libadwaita), NetworkManager, systemd, `iptables`
- A Wi-Fi card that can run a client and an access point at once. Check:
  `iw list | grep -A8 "valid interface combinations"` must show a line with `managed` and `AP`.
- The hotspot runs on the **same channel (and band) as the Wi-Fi you are connected to**. One radio, one channel.
  2.4 and 5 GHz at the same time is not possible.

## Install

### Option 1: APT (recommended)

```bash
curl -fsSL https://sudarsanamr.github.io/wifi-hotspot/setup.sh | sudo bash
sudo apt install wifi-hotspot
```

This adds the signed APT repository and installs wifi-hotspot with all dependencies.

### Option 2: From source

```bash
git clone https://github.com/SudarsanamR/wifi-hotspot.git
cd wifi-hotspot
sudo apt install hostapd dnsmasq-base iw iproute2 iptables polkitd pkexec util-linux python3 \
                 python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 python3-qrcode libnotify-bin
sudo ./install.sh
```

Then open **Wi-Fi Hotspot** from the app grid. A random password is generated on first install.
The installer also adds a toggle to GNOME Quick Settings (log out and back in to see it).

## Use
- GUI: `wifi-hotspot-gui`
- CLI: `sudo wifi-hotspot start | stop | show | clients | secret`
- Quick Settings: the **Hotspot** toggle in the top-right system menu starts/stops the hotspot
- Settings live in `/etc/hotspot.conf` (no password in it). The password is in `/etc/hotspot.secret` (root only).
- Optional keys in `/etc/hotspot.conf`: `STA=<wifi interface>`, `COUNTRY=<2-letter code>`, `SUBNET=<a.b.c>`.

## Security model
- Passwordless sudo only for `wifi-hotspot start` and `wifi-hotspot stop`, for the user who ran the installer.
- Changing settings, blocking, approving, limiting, and revealing the password go through polkit
  (system password prompt). The polkit action keeps the authorization for a few minutes (`auth_admin_keep`).
- The password is passed to the root helper on stdin, never on a command line.
- The backend adds its own firewall chains (`HS_IN`, `HS_FWD`, `HS_NAT`, `HS_ACCT`) and removes them on stop.
- `/run/hotspot-status` is world-readable while the hotspot runs: it lists connected devices (MAC, IP, name).
  Do not use this on a shared multi-user machine if that matters to you.

## Limits
- MAC blocking and approval are bypassable: phones use random MACs, and MACs can be spoofed.
  Changing the password is the sure way to remove someone.
- Upload limits use ingress policing (drops packets); download limits use HTB.
- WPA3 and 5 GHz depend on your card and driver.
- IPv4 only. Clients get no IPv6.

## Uninstall

APT:
```bash
sudo apt remove wifi-hotspot          # keeps settings
sudo apt purge wifi-hotspot           # deletes settings and the saved password too
```

From source:
```bash
sudo ./uninstall.sh          # keeps settings
sudo ./uninstall.sh --purge  # deletes settings and the saved password too
```

## License
MIT, see LICENSE.
