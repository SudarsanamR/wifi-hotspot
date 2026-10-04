#!/usr/bin/env bats
# Tests for the hotspot backend CLI. They run the real script against a temp dir with stubbed
# system tools (see test_helper.bash): no root, no Wi-Fi hardware, nothing outside $T is touched.
# What this cannot prove: driver behavior, real iptables/tc rules, phones joining (HANDOFF.md §7).

load test_helper

setup() { hs_setup; }
teardown() { hs_teardown; }

# ---------- syntax

@test "shell scripts parse" {
  bash -n "$BATS_TEST_DIRNAME/../src/wifi-hotspot"
  bash -n "$BATS_TEST_DIRNAME/../install.sh"
  bash -n "$BATS_TEST_DIRNAME/../uninstall.sh"
}

@test "GUI compiles" {
  python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$BATS_TEST_DIRNAME/../src/wifi-hotspot-gui"
}

# ---------- init and file modes

@test "init creates config files with the right modes and a random password" {
  [ "$(stat -c %a "$T/etc/hotspot.conf")" = 644 ]
  [ "$(stat -c %a "$T/etc/hotspot.secret")" = 600 ]
  for f in deny allow limits; do [ "$(stat -c %a "$T/etc/hotspot.$f")" = 644 ]; done
  run hs secret
  [ "${#output}" -eq 14 ]
  ! grep -q '^PASS=' "$T/etc/hotspot.conf"
}

@test "init migrates an old PASS= line out of the world-readable conf" {
  rm "$T/etc/hotspot.secret"
  echo 'PASS=oldpassword9' >> "$T/etc/hotspot.conf"
  hs init
  ! grep -q '^PASS=' "$T/etc/hotspot.conf"
  [ "$(hs secret)" = oldpassword9 ]
}

@test "root-only commands refuse to run unprivileged" {
  [ "$(/usr/bin/id -u)" != 0 ] || skip "test runner is root"
  rm "$T/bin/id"
  for c in start stop block secret apply limit; do
    run hs $c aa:bb:cc:dd:ee:ff
    [ "$status" -eq 1 ]
    [[ $output == *"run as root"* ]]
  done
}

# ---------- apply (GUI Save path)

@test "apply writes every setting and takes the password from stdin" {
  run hs apply "My Net" 5 20 wpa2wpa3 1 0 15 500 0 <<< "new-password!"
  [ "$status" -eq 0 ]
  [ "$(conf SSID)" = "My Net" ]; [ "$(conf MAXCLIENTS)" = 5 ]; [ "$(conf RATE)" = 20 ]
  [ "$(conf SECURITY)" = wpa2wpa3 ]; [ "$(conf ISOLATE)" = 1 ]; [ "$(conf ALLOWLIST)" = 0 ]
  [ "$(conf IDLE_MIN)" = 15 ]; [ "$(conf CAP_MB)" = 500 ]; [ "$(conf NOTIFY)" = 0 ]
  [ "$(hs secret)" = "new-password!" ]
  [ "$(stat -c %a "$T/etc/hotspot.secret")" = 600 ]
}

@test "apply with empty stdin keeps the current password" {
  old=$(hs secret)
  hs apply Net 8 "" wpa2 0 0 0 0 1 < /dev/null
  [ "$(hs secret)" = "$old" ]
}

@test "apply accepts QR-unfriendly characters in the password" {
  hs apply Net 8 "" wpa2 0 0 0 0 1 <<< 'a;b:c"d,e f\g'
  [ "$(hs secret)" = 'a;b:c"d,e f\g' ]
}

@test "apply rejects bad input and leaves the config untouched" {
  before=$(cat "$T/etc/hotspot.conf" "$T/etc/hotspot.secret")
  bad=(
    '""        8 "" wpa2 0 0 0 0 1'
    '"$(printf %033d 0)" 8 "" wpa2 0 0 0 0 1'
    'Net 0     "" wpa2 0 0 0 0 1'
    'Net 33    "" wpa2 0 0 0 0 1'
    'Net 8     x  wpa2 0 0 0 0 1'
    'Net 8     "" wep  0 0 0 0 1'
    'Net 8     "" wpa2 2 0 0 0 1'
    'Net 8     "" wpa2 0 0 1441 0 1'
    'Net 8     "" wpa2 0 0 0 -1 1'
  )
  for a in "${bad[@]}"; do
    eval "run hs apply $a < /dev/null"
    [ "$status" -eq 1 ] || { echo "accepted: $a"; return 1; }
  done
  for pw in short 'has|pipe' "$(printf %064d 0)"; do
    run hs apply Net 8 "" wpa2 0 0 0 0 1 <<< "$pw"
    [ "$status" -eq 1 ] || { echo "accepted password: $pw"; return 1; }
  done
  [ "$(cat "$T/etc/hotspot.conf" "$T/etc/hotspot.secret")" = "$before" ]
}

@test "SSID length is counted in bytes, not characters" {
  run hs apply "$(printf 'é%.0s' {1..16})" 8 "" wpa2 0 0 0 0 1 < /dev/null   # 32 bytes
  [ "$status" -eq 0 ]
  run hs apply "$(printf 'é%.0s' {1..17})" 8 "" wpa2 0 0 0 0 1 < /dev/null   # 34 bytes
  [ "$status" -eq 1 ]
}

@test "show never prints the password" {
  pw=$(hs secret)
  run hs show
  [ "$status" -eq 0 ]
  [[ $output != *"$pw"* ]]
  [[ $output == *"INTERFACE=wlan0"* ]]
  [[ $output == *"CHANNEL=6"* ]]
}

# ---------- block / allow lists

@test "block and allow keep a MAC on one list only, lower-cased, without duplicates" {
  hs allow AA:BB:CC:DD:EE:FF
  hs block aa:bb:cc:dd:ee:ff
  hs block aa:bb:cc:dd:ee:ff
  [ "$(cat "$T/etc/hotspot.deny")" = aa:bb:cc:dd:ee:ff ]
  [ ! -s "$T/etc/hotspot.allow" ]
  hs allow aa:bb:cc:dd:ee:ff
  [ "$(cat "$T/etc/hotspot.allow")" = aa:bb:cc:dd:ee:ff ]
  [ ! -s "$T/etc/hotspot.deny" ]
  hs disallow aa:bb:cc:dd:ee:ff
  [ ! -s "$T/etc/hotspot.allow" ]
}

@test "malformed MACs are rejected" {
  for m in not-a-mac aa:bb:cc:dd:ee aa:bb:cc:dd:ee:ff:00 'aa:bb:cc:dd:ee:f.' ''; do
    run hs block "$m"
    [ "$status" -eq 1 ]
  done
  [ ! -s "$T/etc/hotspot.deny" ]
}

@test "list changes exit 0 when the hotspot is off and do not call hostapd_cli" {
  run hs block aa:bb:cc:dd:ee:ff
  [ "$status" -eq 0 ]
  ! grep -q hostapd_cli "$T/calls"
}

@test "blocking while up updates hostapd live and kicks the device" {
  mkdir "$T/sys/hstest0"
  hs block aa:bb:cc:dd:ee:ff
  grep -q "hostapd_cli -i hstest0 deny_acl ADD_MAC aa:bb:cc:dd:ee:ff" "$T/calls"
  grep -q "hostapd_cli -i hstest0 deauthenticate aa:bb:cc:dd:ee:ff" "$T/calls"
}

# ---------- per-device limits

@test "limit adds, replaces and clears an entry" {
  hs limit aa:bb:cc:dd:ee:ff 10 5
  hs limit 11:22:33:44:55:66 2 1
  hs limit AA:BB:CC:DD:EE:FF 20 0
  grep -qx "aa:bb:cc:dd:ee:ff 20 0" "$T/etc/hotspot.limits"
  [ "$(grep -c aa:bb "$T/etc/hotspot.limits")" = 1 ]
  hs limit aa:bb:cc:dd:ee:ff 0 0
  ! grep -q aa:bb "$T/etc/hotspot.limits"
  grep -qx "11:22:33:44:55:66 2 1" "$T/etc/hotspot.limits"
}

@test "limit rejects out-of-range values" {
  for a in "1001 0" "0 1001" "-1 0" "x 1" "5"; do
    run hs limit aa:bb:cc:dd:ee:ff $a
    [ "$status" -eq 1 ]
  done
  [ ! -s "$T/etc/hotspot.limits" ]
}

# ---------- start: generated hostapd config

@test "start brings up the AP on the client's channel with a locally administered MAC" {
  run hs start
  [ "$status" -eq 0 ]
  [[ $output == "up: "*" on ch 6 (wlan0, 10.42.50.0/24)" ]]
  grep -q "iw phy phy0 interface add hstest0 type __ap addr 00:11:22:33:44:55" "$T/calls"
  c="$T/run/hotspot-hostapd.conf"
  grep -qx channel=6 "$c"; grep -qx hw_mode=g "$c"; grep -qx country_code=DE "$c"
  grep -q "setsid $T/wifi-hotspot watch" "$T/calls"
  grep -qx "IPF=0" "$T/run/hotspot.state"
}

@test "start omits country_code when the regulatory domain is unknown" {
  : > "$T/fake/cc"
  hs start
  ! grep -q country_code "$T/run/hotspot-hostapd.conf"
}

@test "start uses hw_mode=a on 5 GHz channels" {
  echo 36 > "$T/fake/ch"
  hs start
  grep -qx hw_mode=a "$T/run/hotspot-hostapd.conf"
  grep -qx channel=36 "$T/run/hotspot-hostapd.conf"
}

@test "security modes map to the documented hostapd settings" {
  for m in "wpa2|WPA-PSK|0" "wpa2wpa3|WPA-PSK SAE|1" "wpa3|SAE|2"; do
    IFS='|' read -r sec km pmf <<< "$m"
    hs apply Net 8 "" "$sec" 0 0 0 0 1 <<< "goodpassword"
    hs start
    c="$T/run/hotspot-hostapd.conf"
    grep -qx "wpa_key_mgmt=$km" "$c"; grep -qx "ieee80211w=$pmf" "$c"
    grep -qx "wpa_passphrase=goodpassword" "$c"
    if [ "$sec" = wpa2 ]; then ! grep -q sae_password "$c"; else grep -qx "sae_password=goodpassword" "$c"; fi
    hs stop
  done
}

@test "start moves to another subnet when 10.42.50.0/24 is taken upstream" {
  echo "10.42.50.0/24 dev wlan0 proto kernel scope link" > "$T/fake/routes"
  run hs start
  [[ $output == *"10.42.51.0/24"* ]]
}

@test "start refuses when Wi-Fi is not connected" {
  echo "" > "$T/fake/ch"
  run hs start
  [ "$status" -eq 1 ]
  [[ $output == *"not connected to wifi"* ]]
  [ ! -d "$T/sys/hstest0" ]
}

@test "start twice says already up; stop twice is harmless and cleans up" {
  hs start
  run hs start
  [[ $output == "already up" ]]
  hs stop
  run hs stop
  [ "$status" -eq 0 ]
  [ ! -d "$T/sys/hstest0" ]
  # only the root-only hostapd log stays, on purpose: it is how a failed start gets diagnosed
  [ "$(ls "$T/run")" = hotspot-hostapd.log ]
}

# ---------- watcher

watcher_up() {   # pretend start already ran on channel $1
  mkdir -p "$T/sys/hstest0"
  printf 'channel=%s\n' "$1" > "$T/run/hotspot-hostapd.conf"
  echo STA=wlan0 >> "$T/etc/hotspot.conf"
}

@test "watcher writes the status snapshot with per-device usage and sanitized names" {
  watcher_up 6
  echo 1 > "$T/fake/sleeps"
  echo "Station aa:bb:cc:dd:ee:01 (on hstest0)" > "$T/fake/stations"
  echo "1700000000 AA:BB:CC:DD:EE:01 10.42.50.10 Pixel<7>; *" > "$T/run/hotspot-dnsmasq.leases"
  cat > "$T/fake/iptables-save" <<'EOF'
*filter
:HS_ACCT - [0:0]
[10:1500] -A HS_ACCT -s 10.42.50.10/32
[20:30000] -A HS_ACCT -d 10.42.50.10/32
[0:0] -A HS_ACCT -s 10.42.50.11/32
COMMIT
EOF
  timeout 10 "$T/wifi-hotspot" watch
  grep -qx "TOTAL_BYTES=31500" "$T/run/hotspot-status"
  grep -qx "CHANNEL=6" "$T/run/hotspot-status"
  grep -qP "^CLIENT\taa:bb:cc:dd:ee:01\t10.42.50.10\tPixel7\t30000\t1500\t0\t0$" "$T/run/hotspot-status"
  grep -q "runuser.*Device joined hotspot.*Pixel7" "$T/calls"
}

@test "watcher restarts the AP when the Wi-Fi channel changes" {
  watcher_up 6
  echo 11 > "$T/fake/ch"
  run timeout 10 "$T/wifi-hotspot" watch
  [ "$status" -eq 0 ]
  grep -q "runuser.*Hotspot restarting.*channel 6 to 11" "$T/calls"
  grep -qx channel=11 "$T/run/hotspot-hostapd.conf"
  [ -d "$T/sys/hstest0" ]
}

@test "watcher stops the hotspot when Wi-Fi stays disconnected" {
  watcher_up 6
  echo "" > "$T/fake/ch"
  run timeout 10 "$T/wifi-hotspot" watch
  [ "$status" -eq 0 ]
  grep -q "runuser.*Wi-Fi connection lost" "$T/calls"
  [ ! -d "$T/sys/hstest0" ]
  [ "$(cat "$T/fake/sleepcount")" -ge 4 ]   # needed two checks, not one
}

@test "watcher ignores a single missed channel read (roam / rescan)" {
  watcher_up 6
  printf '\n6\n' > "$T/fake/ch"
  echo 20 > "$T/fake/sleeps"
  timeout 10 "$T/wifi-hotspot" watch
  ! grep -q "connection lost" "$T/calls"
  ! grep -q "restarting" "$T/calls"
}

@test "watcher turns the hotspot off at the data cap" {
  watcher_up 6
  echo CAP_MB=1 >> "$T/etc/hotspot.conf"
  printf '*filter\n[1:2000000] -A HS_ACCT -d 10.42.50.10/32\n[1:0] -A HS_ACCT -s 10.42.50.10/32\nCOMMIT\n' > "$T/fake/iptables-save"
  run timeout 10 "$T/wifi-hotspot" watch
  grep -q "runuser.*Data cap of 1 MB reached" "$T/calls"
  [ ! -d "$T/sys/hstest0" ]
}
