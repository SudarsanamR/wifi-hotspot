# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.0     | ✅         |

## Security Model

- **Passwordless sudo** is granted only for `wifi-hotspot start` and `wifi-hotspot stop`, only for the user who ran the installer.
- **All settings changes, blocking, approving, limiting, and password reveal** require polkit authentication (`auth_admin_keep`).
- The Wi-Fi password is **never** passed on a command line (it goes via stdin to avoid appearing in process listings and system logs).
- The password is stored in `/etc/hotspot.secret` (mode 600, root-only), never in the world-readable `/etc/hotspot.conf`.
- All firewall rules live in dedicated `HS_*` chains and are removed cleanly on stop.

## Known Exposures

- `/run/hotspot-status` is world-readable while the hotspot runs. It lists connected devices (MAC, IP, hostname). On shared multi-user machines this may be a privacy concern.
- MAC-based blocking and approval are bypassable (phones randomize MACs; MACs can be spoofed). Changing the password is the only reliable way to remove access.

## Reporting a Vulnerability

Please report security issues by opening a GitHub issue or emailing the maintainer directly. Do not report security issues in public discussions until a fix is available.
