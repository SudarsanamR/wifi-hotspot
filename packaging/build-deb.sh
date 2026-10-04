#!/bin/bash
# Build a .deb package for wifi-hotspot.
# Usage: bash packaging/build-deb.sh [VERSION]
# Run from the repo root. Output: build/wifi-hotspot_<VERSION>-1_all.deb
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.0}"
PKG="wifi-hotspot_${VERSION}-1_all"

rm -rf "build/$PKG"
mkdir -p "build/$PKG/DEBIAN"
mkdir -p "build/$PKG/usr/local/sbin"
mkdir -p "build/$PKG/usr/local/bin"
mkdir -p "build/$PKG/usr/share/polkit-1/actions"
mkdir -p "build/$PKG/usr/share/applications"
mkdir -p "build/$PKG/usr/share/wifi-hotspot/gnome-extension"
mkdir -p "build/$PKG/etc/NetworkManager/conf.d"

# ── Install files ──
install -m 755 src/wifi-hotspot           "build/$PKG/usr/local/sbin/wifi-hotspot"
install -m 755 src/wifi-hotspot-gui       "build/$PKG/usr/local/bin/wifi-hotspot-gui"
install -m 644 data/local.sudar.hotspot.policy \
                                          "build/$PKG/usr/share/polkit-1/actions/"
install -m 644 data/local.sudar.Hotspot.desktop \
                                          "build/$PKG/usr/share/applications/"
install -m 644 gnome-extension/extension.js \
                                          "build/$PKG/usr/share/wifi-hotspot/gnome-extension/"
install -m 644 gnome-extension/metadata.json \
                                          "build/$PKG/usr/share/wifi-hotspot/gnome-extension/"
install -m 644 data/90-hotspot-ap0.conf   "build/$PKG/etc/NetworkManager/conf.d/"

# ── DEBIAN/control ──
cat > "build/$PKG/DEBIAN/control" <<CTRL
Package: wifi-hotspot
Version: ${VERSION}-1
Section: net
Priority: optional
Architecture: all
Depends: hostapd, dnsmasq-base, iw, iproute2, iptables, pkexec, util-linux, python3, python3-gi, gir1.2-gtk-4.0, gir1.2-adw-1, sudo
Recommends: python3-qrcode, libnotify-bin
Maintainer: Sudarsanam R <sudarsanam2006@gmail.com>
Homepage: https://github.com/SudarsanamR/wifi-hotspot
Description: Share Wi-Fi while staying connected (hostapd GUI)
 A Windows-style Mobile Hotspot for Linux. Creates a virtual access-point
 interface alongside the existing Wi-Fi connection using hostapd, dnsmasq,
 and iptables NAT. Features include a GTK4/libadwaita GUI with per-device
 stats and controls, and a GNOME Quick Settings toggle.
CTRL

# ── DEBIAN/conffiles ──
cat > "build/$PKG/DEBIAN/conffiles" <<'CONF'
/etc/NetworkManager/conf.d/90-hotspot-ap0.conf
CONF

# ── DEBIAN/postinst ──
cat > "build/$PKG/DEBIAN/postinst" <<'POSTINST'
#!/bin/bash
set -e
BIN=/usr/local/sbin/wifi-hotspot
EXT_SRC=/usr/share/wifi-hotspot/gnome-extension
EXT_UUID="wifi-hotspot@local.sudar"

# Disable the distro hostapd service (we start our own instance)
systemctl disable --now hostapd 2>/dev/null || true

# Reload NetworkManager to pick up the ap0 exclusion
systemctl reload NetworkManager 2>/dev/null || true

# Update desktop database
command -v update-desktop-database >/dev/null && update-desktop-database /usr/share/applications || true

# Initialize config (idempotent — preserves existing config and password)
"$BIN" init >/dev/null 2>&1 || true

# Set up sudoers rule for the installing user (same scope as install.sh:
# only start and stop, only for the user who ran sudo apt install)
USER_NAME="${SUDO_USER:-}"
if [ -n "$USER_NAME" ] && [ "$USER_NAME" != root ] && [[ $USER_NAME =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  tmp=$(mktemp)
  echo "$USER_NAME ALL=(root) NOPASSWD: $BIN start, $BIN stop" > "$tmp"
  if visudo -cf "$tmp" >/dev/null 2>&1; then
    install -m 440 -o root -g root "$tmp" /etc/sudoers.d/wifi-hotspot
  fi
  rm -f "$tmp"

  # Install GNOME Shell extension for the user
  USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
  if [ -n "$USER_HOME" ] && [ -d "$EXT_SRC" ]; then
    EXT_DIR="$USER_HOME/.local/share/gnome-shell/extensions/$EXT_UUID"
    install -d -o "$USER_NAME" -g "$(id -g "$USER_NAME")" "$EXT_DIR"
    install -m 644 -o "$USER_NAME" -g "$(id -g "$USER_NAME")" "$EXT_SRC/metadata.json" "$EXT_DIR/"
    install -m 644 -o "$USER_NAME" -g "$(id -g "$USER_NAME")" "$EXT_SRC/extension.js"  "$EXT_DIR/"
    runuser -u "$USER_NAME" -- gnome-extensions enable "$EXT_UUID" 2>/dev/null || true
  fi
fi

echo ""
echo "wifi-hotspot installed!"
echo "  Open 'Wi-Fi Hotspot' from the app grid, or run:  wifi-hotspot-gui"
echo "  CLI:  sudo wifi-hotspot start | stop | show | clients | secret"
echo "  Log out and back in to see the Quick Settings toggle."
POSTINST
chmod 755 "build/$PKG/DEBIAN/postinst"

# ── DEBIAN/prerm ──
cat > "build/$PKG/DEBIAN/prerm" <<'PRERM'
#!/bin/bash
set -e
[ -x /usr/local/sbin/wifi-hotspot ] && /usr/local/sbin/wifi-hotspot stop 2>/dev/null || true
PRERM
chmod 755 "build/$PKG/DEBIAN/prerm"

# ── DEBIAN/postrm ──
cat > "build/$PKG/DEBIAN/postrm" <<'POSTRM'
#!/bin/bash
set -e
EXT_UUID="wifi-hotspot@local.sudar"

if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
  rm -f /etc/sudoers.d/wifi-hotspot
  for d in /home/*/.local/share/gnome-shell/extensions/"$EXT_UUID"; do
    [ -d "$d" ] && rm -rf "$d"
  done
  command -v update-desktop-database >/dev/null && update-desktop-database /usr/share/applications || true
  systemctl reload NetworkManager 2>/dev/null || true
fi

if [ "$1" = "purge" ]; then
  rm -f /etc/hotspot.conf /etc/hotspot.secret /etc/hotspot.deny /etc/hotspot.allow /etc/hotspot.limits
fi
POSTRM
chmod 755 "build/$PKG/DEBIAN/postrm"

# ── Build ──
dpkg-deb --build --root-owner-group "build/$PKG"
echo "Built: build/${PKG}.deb"
