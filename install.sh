#!/bin/bash
# Installs the wifi-hotspot backend, GUI, app-grid entry, polkit action, NetworkManager exclusion for ap0
# and a minimal sudoers rule (start/stop only, for the user who runs this with sudo).
# Usage:  sudo ./install.sh        (run from the folder containing these files)
set -euo pipefail
cd "$(dirname "$0")"

[ "$(id -u)" = 0 ] || { echo "Run with: sudo ./install.sh"; exit 1; }
USER_NAME=${SUDO_USER:-}
{ [ -n "$USER_NAME" ] && [ "$USER_NAME" != root ]; } || { echo "Run it via sudo from your normal user account."; exit 1; }
[[ $USER_NAME =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "Unusual user name '$USER_NAME'; refusing to write a sudoers rule for it."; exit 1; }

missing=()
for c in hostapd dnsmasq iw ip iptables iptables-restore iptables-save tc pkexec python3 runuser setsid visudo; do
  command -v "$c" >/dev/null || missing+=("$c")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "Missing tools: ${missing[*]}"
  echo "Debian/Ubuntu: sudo apt install hostapd dnsmasq-base iw iproute2 iptables polkitd pkexec util-linux sudo python3"
  exit 1
fi
python3 -c 'import gi; gi.require_version("Adw","1")' 2>/dev/null \
  || echo "NOTE: GUI needs: sudo apt install python3-gi gir1.2-gtk-4.0 gir1.2-adw-1  (also python3-qrcode for the QR code, libnotify-bin for notifications)"

# the radio must be able to run a client and an access point at the same time
if iw list 2>/dev/null | grep -A8 'valid interface combinations' | grep -Eq '#\{ managed \} <= [0-9], #\{ AP'; then
  echo "OK: this Wi-Fi card supports client + access point at the same time."
else
  echo "WARNING: 'iw list' does not show a managed + AP combination. The hotspot will probably not start"
  echo "         while this laptop is connected to Wi-Fi."
fi

BIN=/usr/local/sbin/wifi-hotspot

# stop whatever version is running (it may have un-chained firewall rules), including the pre-rename
# "hotspot" binary; then remove the old names so no stale sudoers rule points at them
for old in "$BIN" /usr/local/sbin/hotspot; do
  if [ -x "$old" ]; then "$old" stop || true; fi
done
rm -f /usr/local/sbin/hotspot /usr/local/bin/hotspot-gui /etc/sudoers.d/hotspot

install -m 755 src/wifi-hotspot "$BIN"
install -m 755 src/wifi-hotspot-gui /usr/local/bin/wifi-hotspot-gui
install -m 644 data/local.sudar.hotspot.policy /usr/share/polkit-1/actions/local.sudar.hotspot.policy
install -m 644 data/local.sudar.Hotspot.desktop /usr/share/applications/local.sudar.Hotspot.desktop
install -d /usr/share/icons/hicolor/scalable/apps
install -m 644 data/icons/wifi-hotspot.svg /usr/share/icons/hicolor/scalable/apps/wifi-hotspot.svg
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache /usr/share/icons/hicolor 2>/dev/null || true
command -v update-desktop-database >/dev/null && update-desktop-database /usr/share/applications || true

# NetworkManager must leave the virtual ap0 interface alone, or it fights hostapd for it
if [ -d /etc/NetworkManager ]; then
  install -d /etc/NetworkManager/conf.d
  printf '[keyfile]\nunmanaged-devices=interface-name:ap0\n' > /etc/NetworkManager/conf.d/90-hotspot-ap0.conf
  systemctl reload NetworkManager 2>/dev/null || true
fi

# the distro hostapd service must not run on its own (the script starts hostapd itself)
systemctl disable --now hostapd 2>/dev/null || true

# passwordless ONLY for these two exact commands (start/stop). Everything that changes settings,
# blocks devices or reveals the password goes through polkit and asks for a password.
tmp=$(mktemp)
echo "$USER_NAME ALL=(root) NOPASSWD: $BIN start, $BIN stop" > "$tmp"
visudo -cf "$tmp" >/dev/null
install -m 440 -o root -g root "$tmp" /etc/sudoers.d/wifi-hotspot
rm -f "$tmp"

"$BIN" init >/dev/null     # creates /etc/hotspot.conf and the root-only /etc/hotspot.secret (kept across upgrades)

# GNOME Shell Quick Settings toggle: install the extension for the running user
EXT_UUID="wifi-hotspot@local.sudar"
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
EXT_DIR="$USER_HOME/.local/share/gnome-shell/extensions/$EXT_UUID"
install -d -o "$USER_NAME" -g "$(id -g "$USER_NAME")" "$EXT_DIR"
install -m 644 -o "$USER_NAME" -g "$(id -g "$USER_NAME")" gnome-extension/metadata.json "$EXT_DIR/"
install -m 644 -o "$USER_NAME" -g "$(id -g "$USER_NAME")" gnome-extension/extension.js "$EXT_DIR/"
# Enable the extension (non-fatal: works only under a GNOME session).
# Try gnome-extensions first, then fall back to gsettings (works without D-Bus session).
if ! runuser -u "$USER_NAME" -- gnome-extensions enable "$EXT_UUID" 2>/dev/null; then
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$USER_NAME")/bus" \
    runuser -u "$USER_NAME" -- gsettings get org.gnome.shell enabled-extensions 2>/dev/null | {
      read -r current
      if echo "$current" | grep -q "$EXT_UUID"; then
        : # already listed
      elif [ "$current" = "@as []" ] || [ -z "$current" ]; then
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$USER_NAME")/bus" \
          runuser -u "$USER_NAME" -- gsettings set org.gnome.shell enabled-extensions "['$EXT_UUID']" 2>/dev/null || true
      else
        new=$(echo "$current" | sed "s/]$/, '$EXT_UUID']/")
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$USER_NAME")/bus" \
          runuser -u "$USER_NAME" -- gsettings set org.gnome.shell enabled-extensions "$new" 2>/dev/null || true
      fi
    }
  echo "NOTE: could not auto-enable via gnome-extensions CLI; used gsettings fallback."
  echo "      Log out and back in to activate the Quick Settings toggle."
fi

echo
echo "Installed. Open 'Wi-Fi Hotspot' from the app grid, or run:  wifi-hotspot-gui"
echo "From a terminal:  sudo wifi-hotspot start | stop | show | clients"
echo "A random Wi-Fi password was generated. Show it (and a QR code) in the app, or:  sudo wifi-hotspot secret"
echo "A toggle has been added to GNOME Quick Settings (top-right menu). Log out and back in if it does not appear."

