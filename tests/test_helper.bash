# Mock harness for tests/wifi-hotspot.bats.
#
# The real backend is copied to $T/wifi-hotspot with its fixed paths moved into the temp dir:
#   /etc/hotspot*      -> $T/etc/hotspot*
#   /run/hotspot*      -> $T/run/hotspot*
#   /sys/class/net/X   -> $T/sys/X        (so isup and the STA MAC are controllable)
#   AP=ap0             -> AP=hstest0      (never touches a real interface)
# and $T/bin (first in PATH) holds stubs for every system tool the script calls.
# Every stub call is appended to $T/calls.
#
# Knobs for tests:
#   $T/fake/ch       channel(s) reported for wlan0, one per `iw dev wlan0 info` call
#                    (the last line repeats; an empty line = not connected)
#   $T/fake/cc       output country of `iw reg get` (empty = none)
#   $T/fake/sleeps   watcher: after this many `sleep` calls, ap0 disappears (ends the loop)
#   mkdir $T/sys/hstest0   -> hotspot counts as "up"

SRC="${HOTSPOT_SRC:-$BATS_TEST_DIRNAME/../src/wifi-hotspot}"

hs_setup() {
  T="$(mktemp -d)"
  export T
  mkdir -p "$T/bin" "$T/etc" "$T/run" "$T/sys/wlan0" "$T/fake"
  echo "02:11:22:33:44:55" > "$T/sys/wlan0/address"
  echo 6 > "$T/fake/ch"
  echo DE > "$T/fake/cc"
  : > "$T/calls"
  sed -e "s#/etc/hotspot#$T/etc/hotspot#g" \
      -e "s#/run/hotspot#$T/run/hotspot#g" \
      -e "s#/sys/class/net/#$T/sys/#g" \
      -e 's#^AP=ap0;#AP=hstest0;#' "$SRC" > "$T/wifi-hotspot"
  chmod +x "$T/wifi-hotspot"
  grep -q '^AP=hstest0;' "$T/wifi-hotspot" || { echo "harness: AP rewrite failed" >&2; return 1; }

  # generic stub: log and succeed
  for t in hostapd dnsmasq tc iptables-restore setsid runuser notify-send loginctl hostapd_cli; do
    printf '#!/bin/bash\necho "%s $*" >> "$T/calls"\nexit 0\n' "$t" > "$T/bin/$t"
    chmod +x "$T/bin/$t"
  done

  stub id <<'EOF'
case "$1" in -u) echo 0 ;; -nu) echo tester ;; *) echo "uid=0(root)" ;; esac
EOF
  # -D must fail, otherwise rules_off's "delete until gone" loops never end
  stub iptables <<'EOF'
for a in "$@"; do [ "$a" = -D ] && exit 1; done; exit 0
EOF
  stub iptables-save <<'EOF'
[ -f "$T/fake/iptables-save" ] && cat "$T/fake/iptables-save"; exit 0
EOF
  stub ip <<'EOF'
[ "$1 $2 $3" = "-4 route show" ] && { [ -f "$T/fake/routes" ] && cat "$T/fake/routes"; }; exit 0
EOF
  stub sysctl <<'EOF'
[ "$1" = -n ] && echo 0; exit 0
EOF
  stub sleep <<'EOF'
n=$(( $(cat "$T/fake/sleepcount" 2>/dev/null || echo 0) + 1 )); echo $n > "$T/fake/sleepcount"
max=$(cat "$T/fake/sleeps" 2>/dev/null || echo 1000)
[ "$n" -ge "$max" ] && rmdir "$T/sys/hstest0" 2>/dev/null
exit 0
EOF
  stub iw <<'EOF'
nextch() {   # pop one channel per call; the last one repeats
  local f="$T/fake/ch" c
  c=$(head -n1 "$f")
  [ "$(wc -l < "$f")" -gt 1 ] && sed -i 1d "$f"
  printf %s "$c"
}
case "$*" in
  "dev") printf 'phy#0\n\tInterface wlan0\n\t\ttype managed\n' ;;
  "dev wlan0 info")
    c=$(nextch)
    printf 'Interface wlan0\n\twiphy 0\n\ttype managed\n'
    [ -n "$c" ] && printf '\tchannel %s (2437 MHz), width: 20 MHz\n' "$c" ;;
  "dev hstest0 info") printf 'Interface hstest0\n\tssid x\n\ttype AP\n' ;;
  "dev hstest0 station dump") [ -f "$T/fake/stations" ] && cat "$T/fake/stations" ;;
  "dev hstest0 del") rmdir "$T/sys/hstest0" ;;
  "reg get") cc=$(cat "$T/fake/cc"); [ -n "$cc" ] && printf 'global\ncountry %s: DFS-ETSI\n' "$cc" ;;
  "phy phy0 interface add hstest0"*) mkdir -p "$T/sys/hstest0" ;;
esac
exit 0
EOF
  export PATH="$T/bin:$PATH"
  # SUDO_UID makes the watcher send notifications (through the runuser stub)
  export SUDO_UID=1000
  # first-run init, as the installer would do
  "$T/wifi-hotspot" init > /dev/null
}

hs_teardown() { rm -rf "$T"; }

stub() {   # stub NAME  (body on stdin; every call is also logged)
  { printf '#!/bin/bash\necho "%s $*" >> "$T/calls"\n' "$1"; cat; } > "$T/bin/$1"
  chmod +x "$T/bin/$1"
}

hs() { "$T/wifi-hotspot" "$@"; }
conf() { sed -n "s/^$1=//p" "$T/etc/hotspot.conf"; }
