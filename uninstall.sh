#!/bin/bash
# Removes everything install.sh added (and leftovers of the pre-rename "hotspot" install).
# Settings are kept unless you pass --purge.
set -u
[ "$(id -u)" = 0 ] || { echo "Run with: sudo ./uninstall.sh [--purge]"; exit 1; }
for b in /usr/local/sbin/wifi-hotspot /usr/local/sbin/hotspot; do
  [ -x "$b" ] && "$b" stop
done
rm -f /usr/local/sbin/wifi-hotspot /usr/local/bin/wifi-hotspot-gui \
      /usr/local/sbin/hotspot /usr/local/bin/hotspot-gui \
      /usr/share/polkit-1/actions/local.sudar.hotspot.policy \
      /usr/share/applications/local.sudar.Hotspot.desktop \
      /etc/sudoers.d/wifi-hotspot /etc/sudoers.d/hotspot \
      /etc/NetworkManager/conf.d/90-hotspot-ap0.conf
systemctl reload NetworkManager 2>/dev/null
command -v update-desktop-database >/dev/null && update-desktop-database /usr/share/applications
# remove the GNOME Shell extension for every user that has it
EXT_UUID="wifi-hotspot@local.sudar"
for d in /home/*/.local/share/gnome-shell/extensions/"$EXT_UUID"; do
  [ -d "$d" ] && rm -rf "$d"
done
if [ "${1:-}" = "--purge" ]; then
  rm -f /etc/hotspot.conf /etc/hotspot.secret /etc/hotspot.deny /etc/hotspot.allow /etc/hotspot.limits
  echo "Removed, including settings and the saved password."
else
  echo "Removed. Settings kept in /etc/hotspot.*  (use --purge to delete them too)."
fi
