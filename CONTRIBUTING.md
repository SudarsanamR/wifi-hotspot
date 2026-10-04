# Contributing

Thank you for your interest in contributing!

## How to contribute

1. **Report bugs**: Open a GitHub issue with your system info (see the hardware report template below).
2. **Suggest features**: Open an issue describing your use case.
3. **Submit code**: Fork, create a branch, make your changes, and open a pull request.

## Development setup

```bash
git clone <repo-url> && cd wifi-hotspot
sudo apt install hostapd dnsmasq-base iw iproute2 iptables polkitd pkexec util-linux \
                 python3 python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 python3-qrcode libnotify-bin
sudo ./install.sh
```

## Hard rules (do not break these)

1. **Do not widen the sudoers rule** beyond `wifi-hotspot start` and `wifi-hotspot stop`.
2. **Never pass the Wi-Fi password on a command line** — `pkexec` and `sudo` log command lines. Use stdin.
3. **Keep every firewall rule inside `HS_*` chains** so cleanup stays exact and idempotent.
4. **The AP must use the same channel as the client connection** (hardware limit: `#channels <= 1`).
5. **Do not claim a feature works unless it was tested on real hardware.**

## Testing

Run the checks:
```bash
bash -n src/wifi-hotspot install.sh uninstall.sh          # syntax
python3 -m py_compile src/wifi-hotspot-gui                 # syntax
shellcheck -S warning src/wifi-hotspot install.sh uninstall.sh  # lint
bats tests/                                               # integration tests
```

## Hardware report (for bug reports)

```bash
uname -r; lsb_release -ds; gnome-shell --version
iw list | grep -A8 "valid interface combinations"
iw phy phy0 info | grep -iE "Band [0-9]|MFP|SAE|AP"
lspci -k | grep -A3 -i network   # or: lsusb for USB adapters
sudo wifi-hotspot start; iw dev; sudo cat /run/hotspot-hostapd.log
sudo iptables -S | grep HS_
```
