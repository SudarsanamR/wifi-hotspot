# Changelog

All notable changes to this project will be documented in this file.

## [1.0] — 2026-10-04

### Added
- Backend (`wifi-hotspot`): virtual AP on `ap0` alongside the Wi-Fi client interface, using `hostapd` + `dnsmasq` + `iptables` NAT + `tc` traffic shaping.
- GTK4/libadwaita GUI (`wifi-hotspot-gui`) with: on/off switch, network settings (SSID, password, security mode, max devices, download limit), per-device data usage and live speed, per-device speed limits, block/approve lists, QR code for connecting, idle auto-off, data cap, join/leave notifications.
- Security modes: WPA2, WPA2/WPA3, WPA3-only.
- Firewall rules in dedicated `HS_IN`/`HS_FWD`/`HS_NAT`/`HS_ACCT` chains for clean, idempotent setup/teardown.
- `install.sh` with dependency checks, `iw list` capability verification, NetworkManager exclusion, polkit policy, desktop entry, and scoped sudoers rule.
- `uninstall.sh` with optional `--purge` to remove settings.
- Watcher follows the upstream Wi-Fi: on a channel change it restarts the AP on the new channel; if Wi-Fi is lost for two consecutive checks (~24 s) it stops the hotspot. Both send a desktop notification.
- `country_code` is omitted from the hostapd config when the regulatory domain is unknown.
- A failed start shows the backend error, including the last 5 lines of the hostapd log, in a GUI dialog.
- `tests/test_helper.bash`: mock harness that runs the backend against a temp dir with stubbed `iw`, `iptables`, `tc`, `hostapd`, `dnsmasq`, etc.
- 29 bats tests covering init/migration, root gating, `apply` validation, ACL lists, limits, generated hostapd config, start/stop idempotency and the watcher.
- **GNOME Quick Settings toggle** (`gnome-extension/`): native GNOME Shell extension that adds a Hotspot on/off toggle to the system menu. Polls `iw dev` every 4 s to sync state. Installed and enabled automatically by `install.sh`; no third-party extension required.
- CI pipeline: shellcheck, ruff, bats tests, tarball build with SHA-256 checksums.

### Known limitations
- Single radio, single channel: AP follows the connected Wi-Fi's channel and band.
- Requires an active Wi-Fi client connection (no Ethernet-only upstream).
- MAC-based blocking is bypassable (random/rotating MACs).
- IPv4 only.
- Not tested beyond one laptop (Ubuntu 26.04, GNOME 50.1, Realtek RTL8852CE).
