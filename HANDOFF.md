# Wi-Fi Hotspot for Linux: Project Handoff

Date: 2026-10-04  
Owner: Sudarsanam R  
Version: v1.0  
Purpose of this file: complete record of what was built, how it works, what has and has not been tested, and what remains. Written so a new engineer or AI assistant can continue without the original chat.

---

## 0. Summary

**Goal.** A Windows-style "Mobile Hotspot" for Ubuntu: share the laptop's Wi-Fi *while staying connected to that same Wi-Fi*, with a proper GUI (name, password, security mode, device list, limits, blocklist, QR code) and a one-click toggle in the GNOME top-right menu.

**Why it needed building.** GNOME's built-in hotspot switch takes over the Wi-Fi interface and drops the current connection. This project instead creates a second virtual access-point interface (`ap0`) on the same radio and runs `hostapd` + `dnsmasq` + NAT on it.

**State.** Working end to end on the owner's laptop (phone joins, gets an IP, has internet; GUI runs). The final packaged release (installer, firewall chain for DHCP/DNS, NetworkManager exclusion) was assembled and statically checked but **not yet run on real hardware**. Several features were only tested with mocks (see §6 and §7).

**Deliverables (canonical):**

| File | Role |
|---|---|
| `hotspot-0.1.tar.gz` | Pre-v1.0 development tarball (superseded by the repo; kept as a record) |
| `README.md` | User-facing readme |
| `HANDOFF.md` | This document |

Files in the older `hotspot-gui/` output folder (13.5 KB `hotspot`, 20.6 KB `hotspot-gui`) are **superseded v3 builds. Do not use them.**

Tarball SHA-256: `54677c51a1eb7315706485cfee1db1506f11e012f222d41ae3d7f5c10ca6ccde`

> [!IMPORTANT]
> **Update 2026-10-04 (session 2):** the source now lives in the repo layout of §11.1 (`src/`, `data/`, `tests/`, `gnome-extension/`, `.github/`). `hotspot-0.1.tar.gz` and the hashes below are superseded; the v1.0 release tarball is built by CI from a `v*` tag.

Contents of the old `hotspot-0.1/` (for historical reference):

| File | SHA-256 | Lines |
|---|---|---|
| `hotspot` (backend) | `63c79f0f358bd3bfc005ad0dd7c5c0b1bcf99de7a16508b240f09c33be2598ad` | 398 |
| `hotspot-gui` (GTK4 app) | `2592f64fb51a9d496d1f954fa62ebc730f31d935af0b5d4effc9d7c4e47ab72e` | 589 |
| `install.sh` | `96df7c4a674a64f423de5b287619e552bc4887952c9461cc057adc083c8bd670` | 65 |
| `uninstall.sh` | `0869b0091482f38476532202a083b42af6b40fd8852212ab2def372bcc5d1c0e` | 17 |
| `local_sudar_hotspot.policy` | `ef8e2f7092f6a915e103a51c9c57251810029d76427f453a285bfd68e7dfa282` | 17 |
| `local.sudar.Hotspot.desktop` | `1174024cbf99261b1dec5f9b054602f2a2144fa385a06fabb58516d9d2b8378d` | 10 |
| `LICENSE` (MIT, placeholder) | `ff21fe013a3b1adf4e67c372b9bd8b4763891af323e961d79c5c00d8bf5426c4` | n/a |
| `README.md` | `90759b49c694fe4f274821434cc5a4c887421018140291a51e4e6c2f122e7d0f` | n/a |

---

## 1. Context: the owner's machine

- Lenovo laptop, Ubuntu "resolute" (26.04 series), GNOME Shell 50.1, libadwaita 1.9.1, GTK 4.22
- Wi-Fi interface `wlp3s0` on `phy0`; Ethernet `enp2s0` (unplugged); `docker0` present (Docker sets FORWARD policy DROP)
- `ufw` active (INPUT policy DROP; only port 51413 allowed originally)
- NetworkManager manages Wi-Fi
- Radio capability from `iw list`:
  `#{ managed } <= 1, #{ AP, P2P-client, P2P-GO } <= 1, total <= 2, #channels <= 1`
  This is what makes the whole approach possible: one client + one AP at once, **on one channel only**.
- Wi-Fi chipset/driver was never identified (owner never ran `lspci -k | grep -A3 -i network`). This matters for WPA3 and 5 GHz support.
- Upstream network at test time: 2.4 GHz channel 5.

---

## 2. Brief to paste into the next assistant (e.g. Antigravity)

> You are continuing a Linux project: a Wi-Fi hotspot manager that runs a virtual AP interface (`ap0`) alongside the client connection on one radio. Backend: bash script `wifi-hotspot` (root; hostapd + dnsmasq + iptables + tc). Frontend: Python GTK4/libadwaita app `wifi-hotspot-gui`. v1.0 source is in the repo. Read `HANDOFF.md` fully before changing anything. Hard rules: (1) do not widen the sudoers rule beyond `wifi-hotspot start` and `wifi-hotspot stop`; (2) never pass the Wi-Fi password on a command line (`pkexec` and `sudo` log command lines); `apply` reads it from stdin; (3) keep every firewall rule inside the `HS_*` chains so cleanup stays exact and idempotent; (4) the AP must use the same channel as the client connection (hardware limit); (5) do not claim a feature works unless it was run on real hardware. Next tasks are in §7 (pre-release checklist) and §10 (backlog).

---

## 3. How it works

### 3.1 Data flow

```
Phone ──Wi-Fi──► ap0 (virtual AP, hostapd) ──► kernel forwarding + NAT (iptables) ──► wlp3s0 ──► router ──► internet
                    │
                    ├─ dnsmasq: DHCP (10.42.50.10–.50) + DNS forwarding on ap0 only
                    ├─ tc HTB (egress) + ingress policing: speed limits
                    ├─ iptables HS_ACCT: per-IP byte counters
                    └─ `hotspot watch` (root, background): status file, notifications, idle-off, data cap
```

### 3.2 Why this design (decisions not to reverse without a reason)

| Decision | Reason |
|---|---|
| hostapd on a virtual `ap0`, not NetworkManager's AP mode | NM's AP mode cannot do per-client block, max clients, ACLs, isolation, or WPA3 options at this level |
| `ap0` MAC = STA MAC XOR `0x02` (locally administered bit) | Copying the STA MAC gave `RTNETLINK: Name not unique on network` and `ap0` never came up (first failure in this project) |
| AP channel = STA channel | Hardware: `#channels <= 1`. Also means **no simultaneous 2.4 + 5 GHz** and the hotspot band follows the Wi-Fi band |
| NM told to ignore `ap0` (`unmanaged-devices=interface-name:ap0`) | Otherwise NM grabs the interface |
| Own iptables chains `HS_IN`, `HS_FWD`, `HS_NAT`, `HS_ACCT` | Exact, idempotent cleanup. Rules inserted at position 1 so Docker's FORWARD DROP and ufw's INPUT DROP do not block the hotspot |
| `HS_IN` accepts udp/67, udp/53, tcp/53 on `ap0` | With ufw active, DHCP requests were dropped and phones showed "IP configuration failed" (second failure). Originally patched with ufw rules; now in the script |
| Password via stdin to `apply` | `pkexec`/`sudo` write the full command line to logs |
| Password in `/etc/hotspot.secret` (mode 600), not in `hotspot.conf` | `hotspot.conf` is world-readable so the GUI can read settings without root |
| `|` forbidden in passwords | hostapd's `sae_password` treats `|` as an option separator |
| sudoers: only `start` / `stop` | Passwordless root for settings commands would let any program running as the user change the hotspot or read the password |
| Upload limit = ingress policing, not IFB | No kernel module dependency; trade-off: drops packets instead of queueing |
| Per-device limits matched by MAC (`flower`) | Robust to IP changes. Needs `cls_flower` in the kernel |
| DHCP range limited to 41 addresses (.10–.50) | One counting rule pair per address; keeps rule count at 82. Max devices therefore capped at 32 |
| Allow-list and deny-list are mutually exclusive in the script | hostapd's precedence between `accept_mac_file` and `deny_mac_file` was not verified, so overlap is avoided |
| `stop_pid` checks `/proc/<pid>/comm` before killing | Never kill a recycled PID |
| Status snapshot file `/run/hotspot-status` written by the watcher | GUI polls a file; no sudo, no process spawns |

### 3.3 File and path map

Installed:

| Path | Purpose |
|---|---|
| `/usr/local/sbin/wifi-hotspot` | Backend (bash, root) |
| `/usr/local/bin/wifi-hotspot-gui` | GUI (Python, runs as user) |
| `/usr/share/polkit-1/actions/local.sudar.hotspot.policy` | polkit action `local.sudar.hotspot.run`, bound to the backend path, `auth_admin_keep` |
| `/usr/share/applications/local.sudar.Hotspot.desktop` | App-grid entry |
| `/etc/NetworkManager/conf.d/90-hotspot-ap0.conf` | `unmanaged-devices=interface-name:ap0` |
| `/etc/sudoers.d/wifi-hotspot` | `<user> ALL=(root) NOPASSWD: /usr/local/sbin/wifi-hotspot start, /usr/local/sbin/wifi-hotspot stop` |
| `~/.local/share/gnome-shell/extensions/wifi-hotspot@local.sudar/` | GNOME Quick Settings toggle (per-user, installed by `install.sh`) |

Config (created by `wifi-hotspot init`):

| Path | Mode | Content |
|---|---|---|
| `/etc/hotspot.conf` | 644 | Settings (no password) |
| `/etc/hotspot.secret` | 600 | `PASS=...` (random 14 chars on first run, or migrated from an old `PASS=` line) |
| `/etc/hotspot.deny` | 644 | Blocked MACs |
| `/etc/hotspot.allow` | 644 | Approved MACs |
| `/etc/hotspot.limits` | 644 | `mac down_mbit up_mbit` per line |

Runtime (`/run`): `hotspot-hostapd.conf` / `.pid` / `.log`, `hotspot-dnsmasq.pid` / `.leases`, `hotspot-watch.pid`, `hotspot-status` (644), `hotspot.state` (`STA`, `NET`, `IPF` = original `ip_forward`).

### 3.4 `hotspot.conf` keys

| Key | Values | Default | Notes |
|---|---|---|---|
| `SSID` | 1–32 bytes | `<hostname>-Hotspot` | |
| `MAXCLIENTS` | 1–32 | 8 | hostapd `max_num_sta` |
| `RATE` | Mbit/s, empty = none | empty | Total download cap (HTB parent class) |
| `SECURITY` | `wpa2` / `wpa2wpa3` / `wpa3` | `wpa2` | |
| `ISOLATE` | 0/1 | 0 | `ap_isolate` |
| `ALLOWLIST` | 0/1 | 0 | Approved-only mode (`macaddr_acl=1`) |
| `IDLE_MIN` | 0–1440 | 0 | Auto-off with no device; 0 = off |
| `CAP_MB` | integer MB | 0 | Session data cap; 0 = off |
| `NOTIFY` | 0/1 | 1 | Join/leave desktop notifications |
| `STA`, `COUNTRY`, `SUBNET` | optional overrides | auto | Wi-Fi interface, 2-letter regulatory code, `a.b.c` subnet |

### 3.5 Backend CLI

Needs root: `start stop restart ssid pass max rate security block unblock allow disallow limit secret apply watch init`  
No root needed: `clients blocked show`

| Command | Effect |
|---|---|
| `start` | Detect STA/phy/channel/country, pick subnet, create `ap0`, write hostapd conf, start hostapd + dnsmasq, set firewall chains, counters, shaping, start the watcher. Output ends with `up: <ssid> on ch <n> (<iface>, <net>.0/24)` |
| `stop` | Kill watcher/hostapd/dnsmasq (PID verified), remove all `HS_*` chains, delete `ap0`, restore `ip_forward`, delete status/state files |
| `apply SSID MAX RATE SEC ISO ACL IDLE CAPMB NOTIFY` + password on stdin | Validate everything, write config, restart the hotspot if it is up. Turning ACL on auto-approves currently connected devices |
| `block` / `unblock` / `allow` / `disallow MAC` | Edit lists; if up, also call `hostapd_cli` (`deny_acl`, `accept_acl`, `deauthenticate`) |
| `limit MAC DOWN UP` | 0 0 removes; rebuilds shaping if up |
| `clients` | Tab-separated: `MAC IP NAME DOWN_B UP_B LIMIT_DOWN LIMIT_UP` from the status file |
| `show` | Settings + `CHANNEL`, `INTERFACE`, `ALLOWED`, `TOTAL_BYTES`. Never prints the password |
| `secret` | Prints the password (root; GUI calls via pkexec) |

### 3.6 hostapd mapping

`SECURITY` → `wpa_key_mgmt` / `ieee80211w`: wpa2 → `WPA-PSK` / 0; wpa2wpa3 → `WPA-PSK SAE` / 1; wpa3 → `SAE` / 2.  
SAE modes also set `sae_pwe=2`, `sae_require_mfp=1`, `sae_password=<pass>` (and `wpa_passphrase`).  
Also: `ap_isolate`, `macaddr_acl`, `deny_mac_file`, `accept_mac_file`, `max_num_sta`, `country_code` (from `COUNTRY` or `iw reg get`; omitted when unknown), `hw_mode` g/a from the channel, `ieee80211n=1`, `wmm_enabled=1`.

### 3.7 Watcher (`hotspot watch`)

One background root process (`setsid`), loop every 3 s: read dnsmasq leases and station list; write `/run/hotspot-status`; send join/leave notifications (waits up to 8 s for a DHCP hostname); stop the hotspot when idle for `IDLE_MIN` minutes or total bytes ≥ `CAP_MB`. Every 4th cycle (~12 s) it checks the STA channel: if it changed, it restarts the hotspot on the new channel (and notifies if the restart fails). If the STA has no channel on two checks in a row (~24 s), it stops the hotspot. Notifications go through `runuser -u <user> -- env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/<uid>/bus notify-send`. UID comes from `SUDO_UID` / `PKEXEC_UID`, else the first logged-in user with UID ≥ 1000. Device names from DHCP are sanitized to `[A-Za-z0-9 ._-]`.

### 3.8 GUI (`hotspot-gui`)

Python + PyGObject, GTK4 + libadwaita (needs `Adw.Dialog`/`AlertDialog`, libadwaita ≥ 1.5). Application ID `local.sudar.Hotspot` (placeholder).

Sections: on/off switch (subtitle shows SSID, data used, cap) · **Network** (name, new password, security, band row, max devices, total download limit) · **Options** (isolate, approved-only, idle minutes, data cap GB, notifications, **Save**) · **Connect a device** (Show: password + QR) · **Connected devices** (data ↓↑, live speed, limit; ⋮ menu: Limit speed / Approve / Block) · **Approved devices** (+ add MAC) · **Blocked devices**.

Behavior: reads `/etc/hotspot.*` and `/run/hotspot-status` directly every 2 s (skips when the window is suspended); start/stop via `sudo -n` (falls back to pkexec if sudo asks for a password); everything else via `pkexec`. QR is `WIFI:T:WPA;S:..;P:..;;` (`T:SAE` for WPA3-only), drawn into a `Gdk.MemoryTexture` using `python3-qrcode`.

### 3.9 Security model

- Passwordless root: only `hotspot start` and `hotspot stop` (written for the single user who ran the installer).
- Settings, block/approve, limits, password reveal: polkit (`auth_admin_keep`, about 5 minutes retention; believed to be per calling process, **not verified**).
- Password never on a command line; never in `hotspot.conf`; `hotspot.secret` is 600.
- Inputs validated in `apply`, `limit`, `block`, etc. (regex for MACs, integers, SSID byte length, password length and `|`).
- Known exposure: `/run/hotspot-status` is world-readable and lists connected devices (MAC, IP, name).

---

## 4. Development history

1. **Start.** The owner tried ChatGPT's recipe (`iw phy phy0 interface add ap0 ...` + `nmcli`). Failed.
   - Typo `type__ap` with no space created `ap0` as `managed`.
   - Real cause: `ap0` copied the STA MAC → `ip link set ap0 up` returned `Name not unique on network` → NM showed it `unavailable`.
   - Confirmed from `iw list` that one client + one AP on one channel is supported.
2. **Engine v1.** Switched from NM AP mode to `hostapd` + `dnsmasq` + iptables NAT with a locally-administered MAC. `ap0` came up and phones saw the SSID.
3. **DHCP failure.** Phone joined but showed "IP configuration failed". Foreground `dnsmasq` log showed no `DHCPDISCOVER`. Cause: ufw INPUT DROP. Fixed with narrow ufw rules (67/udp, 53, route allow). A first, too-broad `ufw allow in on ap0` was replaced after the risk was noted.
4. **Quick Settings button.** GNOME 50.1; the "Custom Command Toggle" extension was installed and configured (ON `sudo -n /usr/local/sbin/hotspot start`, OFF `... stop`, icon `network-wireless-hotspot-symbolic`). Recommended status check `iw dev` / search term `type AP`, synced state, initial state auto-detect. Extension compatibility with GNOME 50 was not verified from its listing (v11 listed 45–49); the owner's screenshot showed its preferences opening. Whether the button toggles reliably was not reported.
5. **GUI v1** (GTK4/libadwaita): switch, SSID, password, max devices, download limit, connected list, block list.
6. **GUI v2:** security dropdown (WPA2 / WPA2+WPA3 / WPA3), band row, QR + password reveal via polkit, per-device data usage. Owner confirmed "v2 works".
7. **Backend + GUI v3, seven extras:** isolation, idle auto-off, data cap, live speed, join/leave notifications, approved-only mode, per-device speed limit. Added a polkit policy to reduce password prompts. Fixed a bug where block/unblock/etc. returned exit status 1 when the hotspot was off (GUI would show a false "Failed").
8. **Owner's refactor (uploaded).** Backend and GUI were reworked outside the chat (origin not recorded): interface/phy/country/subnet auto-detection, secret file split, `HS_FWD`/`HS_NAT` chains, `stop_pid`, ip_forward restore, trap on INT/TERM, status snapshot file, GUI reads files directly, Python 3 cleanups. Reviewed in this chat: syntax OK, shellcheck clean at warning level except one unused variable, GUI renders.
9. **Release prep (this chat's last step).** Added to the uploaded version: the `HS_IN` firewall chain (DHCP/DNS), improved `install.sh` (dependency check, `iw list` capability check, NM exclusion, desktop entry, disables the distro hostapd service, username validation), `uninstall.sh` (`--purge`), desktop file, README, MIT license, tarball.
10. **Review of an externally generated packaging guide** (a `.deb` + unsigned APT repo + GNOME extension). Not adopted; see §11.

---

## 5. Test environment note

All automated checks ran in an Ubuntu 24.04 sandbox (GTK 4.14, libadwaita 1.5), not on the owner's machine. The sandbox kernel has no `cls_flower`, no `dummy` network device, and no Wi-Fi hardware.

---

## 6. Verification status

### Verified (sandbox)

- `bash -n` on `hotspot`, `install.sh`, `uninstall.sh`; `py_compile` on `hotspot-gui`; shellcheck: no errors, one SC2034 (unused `exp`) warning in `hotspot`.
- Config/ACL logic with temp files: `apply` validation (good and bad inputs), `allow`/`block`/`disallow` mutual exclusion, `limit` add/clear/reject, `show`, exit status 0 on success.
- `usage()` parser against sample `iptables-save -c` output; real `iptables-restore --noflush` chain creation for `HS_ACCT`, and `HS_IN`/`HS_FWD`/`HS_ACCT` create/teardown/double-create/double-teardown in a throwaway network namespace.
- tc: HTB root, classes, ingress qdisc created in a namespace. (Filters not testable.)
- Watcher loop with mocked stations, leases, clock, counters: join/leave notification (including DHCP-delay and name sanitizing), idle auto-off, data-cap auto-off.
- GUI under Xvfb with mock backends: main window, limit dialog, connect dialog with QR (payload escaping and pixel-buffer math checked), device list with live speed, ⋮ menu, approved/blocked lists, status-file parser (including stale-file rejection).

### Verified (session 2, owner's laptop, no root, mocks only)

- shellcheck 0.10 `-S warning`: clean on `src/hotspot`, `install.sh`, `uninstall.sh`, `tests/test_helper.bash`. ruff `E9,F` clean on the GUI. `xmllint` clean on the policy.
- `bats tests/`: 29/29 pass. The harness (`tests/test_helper.bash`) runs the **real** backend with paths moved to a temp dir and stubbed `iw`/`iptables`/`tc`/`hostapd`/`dnsmasq`/`sleep`. It covers init and migration, root gating, `apply` validation, ACL exclusivity, limits, the generated hostapd config (channel, band, country omission, all 3 security modes, subnet shift), start/stop idempotency, and the watcher (status snapshot, channel follow, disconnect, single-miss tolerance, data cap).
- Mutation check: 6 injected bugs (IN fallback, stop on first miss, block not clearing allow, `|` allowed, AP MAC = STA MAC, wrong WPA3 PMF) were each caught by the suite.
- GUI start-failure dialog: **not** exercised (no display test this session).

### Verified on the owner's hardware (earlier versions)

- Virtual AP `ap0` alongside `wlp3s0`; phone joins; DHCP after ufw fix; phone has internet; CLI commands (`ssid`, `pass`, `max`, `restart`, `clients`); passwordless start/stop via sudoers; GUI v2 opens and works.

### NOT verified anywhere

See the checklist in §7. Treat every item as unproven until run.

---

## 7. Pending: must do before publishing (checklist)

Run on the owner's laptop. Start from a clean state: `sudo wifi-hotspot stop`, then install from the repo.

### 7.1 Install and clean state

```bash
cd wifi-hotspot && sudo ./install.sh
cat /etc/sudoers.d/wifi-hotspot /etc/NetworkManager/conf.d/90-hotspot-ap0.conf
ls -l /etc/hotspot.* /usr/share/polkit-1/actions/local.sudar.hotspot.policy /usr/share/applications/local.sudar.Hotspot.desktop
```
- [ ] Installer runs with no error; the "OK: client + access point" message appears.
- [ ] App appears in the app grid as "Wi-Fi Hotspot".
- [ ] `/etc/hotspot.secret` is mode 600; `/etc/hotspot.conf` has no `PASS=`.
- [ ] Old password migration: the previous weak password was moved, not lost. **Owner must change it.**

### 7.2 Core function, with ufw ACTIVE

- [ ] `sudo hotspot start`; `iw dev` shows `ap0` type AP on the same channel as `wlp3s0`.
- [ ] Phone joins, gets `10.42.50.x`, loads a site (this proves `HS_IN`, NAT and DNS).
- [ ] Remove the old manual ufw rules (67/udp, 53, route allow) and repeat: must still work.
- [ ] Docker running while the hotspot is up: internet still works for the phone.
- [ ] `sudo hotspot stop` leaves nothing behind:
```bash
sudo iptables -S | grep HS_ ; sudo iptables -t nat -S | grep HS_
iw dev ; sysctl net.ipv4.ip_forward ; ls /run/hotspot* 2>&1
```
  Expect no `HS_*` rules, no `ap0`, `ip_forward` back to its original value (Docker hosts usually start at 1), and no `/run/hotspot*` files except `hotspot-hostapd.log` (root-only, kept on purpose to diagnose failed starts) and dnsmasq's lease file.
- [ ] Interrupt `start` with Ctrl-C mid-way: clean state afterwards.
- [ ] Start twice (second says "already up"); stop twice (no error).

### 7.3 Features

- [ ] **Security modes:** WPA2, WPA2/WPA3, WPA3-only each start and a phone joins. If WPA3 fails, capture `/run/hotspot-hostapd.log` and `iw phy phy0 info | grep -iE "MFP|SAE"`.
- [ ] **QR:** Show → system password prompt → QR scans with a phone camera and joins (test WPA2 and WPA3).
- [ ] **Password change** via GUI Save; reconnect with the new one. Test a password containing `;`, `:`, `"`, `,` and a space for the QR payload.
- [ ] **Per-device data and live speed** move while streaming; counters reset on restart.
- [ ] **Per-device limit:** set 2 down / 1 up, run a speed test, then
  `sudo tc filter show dev ap0 parent 1:` and `sudo tc filter show dev ap0 parent ffff:` must list filters. If not: `lsmod | grep cls_` and load `cls_flower`.
- [ ] **Total download limit** (`RATE`) is honored.
- [ ] **Block** a connected phone → kicked, cannot rejoin; **Unblock** → can rejoin.
- [ ] **Approved-only:** turn on with a phone connected (it stays); a second phone is rejected until its MAC is added; remove approval → kicked.
- [ ] **Isolation:** two phones cannot ping each other when on.
- [ ] **Idle auto-off** (1 minute), **data cap** (0.1 GB), **notifications** (join and leave appear).
- [ ] **Quick Settings toggle** (Custom Command Toggle): start/stop works and follows state after `sudo hotspot stop`/`start` in a terminal.
- [ ] **polkit retention:** after one password entry, how long until the next prompt? Confirm another process cannot reuse it.

### 7.4 Robustness

- [ ] Reboot: no leftover state; hotspot off by design.
- [ ] Suspend/resume with the hotspot on: what state results? (known gap, see §10)
- [ ] Wi-Fi router changes channel while the hotspot runs: expect a "Hotspot restarting" notification within ~12 s and the AP back on the new channel (session-2 feature, mock-tested only).
- [ ] Wi-Fi disconnects while the hotspot runs: expect "Wi-Fi connection lost" within ~24 s and a clean stop. Roaming between APs of the same network must **not** trigger it.
- [ ] Upstream network already using `10.42.50.0/24`: subnet shifts to `10.42.51+`.
- [ ] Second user account on the machine; second Wi-Fi interface; no Wi-Fi connected (`start` must print "not connected to wifi").

### 7.5 Other machines / distros (beta feedback)

Ubuntu 22.04/24.04 (older libadwaita: `Adw.Dialog` needs ≥ 1.5, so 22.04 will fail), Debian 12/13, Fedora (uses firewalld and nftables; likely needs changes), Intel vs Realtek vs Atheros/MediaTek cards.

---

## 8. Known limitations (by design or hardware)

- One radio, one channel: the hotspot always uses the upstream Wi-Fi's channel and band. No dual-band, no choosing the hotspot band independently. To get 5 GHz, connect the laptop to a 5 GHz network. 5 GHz AP may fail on DFS channels or when the regulatory flags forbid initiating radiation.
- Requires a Wi-Fi *client* connection to exist; Ethernet-only upstream is not supported (the script derives the channel from the connected Wi-Fi interface).
- NAT is hard-wired to `-o <STA>`; if internet comes via another interface or a VPN, clients get no internet.
- Blocking and approval by MAC are bypassable (random/rotating MACs, spoofing). Per-network randomized MACs change when the SSID changes, which invalidates every list entry. Changing the password is the only reliable removal.
- Data usage only lists connected devices; counters reset on every restart; Save restarts the hotspot.
- Upload limit uses policing (drops packets; crude); download uses HTB. Global cap only applies to download.
- Isolation can break casting, printing, AirDrop-like features.
- IPv4 only.
- DHCP pool is 41 addresses; max devices 32.
- Password rules: 8–63 characters, no `|`.
- `/run/hotspot-status` is world-readable (device privacy on shared machines).
- Not autostarted (deliberate): no hotspot after reboot.
- Linux only; Debian/Ubuntu family + GNOME + NetworkManager + iptables assumed.

---

## 9. Defects and risks spotted but not resolved

1. ~~**Country-code fallback `IN`**~~ **Fixed (session 2):** `country_code` is omitted when unknown; set `COUNTRY=` in `hotspot.conf` to force one.
2. **Hard-coded interface name `ap0`** may collide with other tools.
3. **Hard-coded DHCP DNS behavior:** dnsmasq forwards via `/etc/resolv.conf` (systemd-resolved stub). Worked on the owner's machine; untested with other resolvers.
4. ~~**Unused variable** `exp` in `watch`~~ **Fixed (session 2).**
5. **Custom Command Toggle compatibility with GNOME 50** is unconfirmed beyond the prefs window opening.
6. **polkit `auth_admin_keep` scope** assumed per-process, not verified.
7. **`ieee80211w` / `sae_password` / `wpa_passphrase` combination** assumed from hostapd docs; never ran on the owner's driver.
8. **Quick-start race:** `watch` is started in the background; the status file may not exist for the first ~3 s, so the GUI shows no devices briefly.
9. **Licence** is a placeholder (MIT). Owner has not chosen.

---

## 10. Improvement backlog

### P1: correctness and robustness
- ~~Follow channel changes~~ **Done (session 2, mock-tested):** watcher restarts on a channel change.
- Handle suspend/resume: reconcile `ap0`/hostapd/dnsmasq state. (Wi-Fi drop → stop is **done** in session 2, mock-tested.)
- Determine the uplink from the default route (supports Ethernet/VPN upstream) and allow an AP channel choice when upstream is wired.
- ~~bats tests with mock harness~~ **Done (session 2):** `tests/`. Still open: GUI smoke test under Xvfb in CI.
- ~~Better error surfacing in the GUI~~ **Done (session 2):** start failures open a dialog with the backend message + last 5 hostapd log lines. Not yet seen on screen.
- ~~Remove the hard-coded `IN` country fallback~~ **Done (session 2).**

### P2: security and privacy
- Make `/run/hotspot-status` readable only by a `hotspot` group or the installing user (ACL) instead of world.
- Re-verify polkit retention scope; consider `auth_admin` (no keep) as the default and make `keep` opt-in.
- Optional audit logging of block/approve/limit actions.
- Pending-device list for approved-only mode (hostapd does not report rejected attempts at default log level; would need event hooks via `hostapd_cli -a`).

### P3: features
- ~~Native GNOME Quick Settings extension~~ → **done** (session 2): `gnome-extension/extension.js`, installed by `install.sh`. See Appendix A.
- Persistent usage history (daily/monthly per device).
- Upload limiting with IFB; per-device limit list view for devices not currently connected.
- Scheduling (on/off times), auto-start option with a warning.
- Optional hidden SSID is **not** recommended (no real security).
- Localization, accessibility pass, dark/light QR theming, custom icons (current icon `network-wireless` is a stock icon).
- Support nftables natively (needed for Fedora/firewalld systems), 6 GHz awareness, IPv6.

---

## 11. Packaging and publishing plan

### 11.1 Recommended repo layout

```
wifi-hotspot/
├─ README.md   LICENSE   CHANGELOG.md   SECURITY.md   CONTRIBUTING.md
├─ src/wifi-hotspot            src/wifi-hotspot-gui
├─ gnome-extension/extension.js   gnome-extension/metadata.json
├─ data/local.sudar.hotspot.policy   data/<app-id>.desktop   data/90-hotspot-ap0.conf
├─ install.sh   uninstall.sh
├─ tests/ (bats + mock tools + gui smoke)
├─ docs/ (screenshots, hardware-compat.md)
└─ .github/ (workflows/ci.yml, ISSUE_TEMPLATE/bug.yml)
```

### 11.2 CI (GitHub Actions)

`shellcheck` on shell files, `python3 -m py_compile` + `ruff`/`flake8` on the GUI, `xmllint` on the policy file, bats tests, tarball build with SHA-256 checksums attached to the release.

### 11.3 Release distribution

- v1.0: GitHub Release with the tarball and a `SHA256SUMS` file.
- Later: a proper `.deb` (see warnings below), or a **signed** APT repo.

### 11.4 Warnings about the externally generated packaging guide (do not follow as written)

- Its `postinst` writes passwordless sudo for **all sudo users** (and the sample was truncated). The installer here writes it only for the installing user and only for `start`/`stop`.
- `[trusted=yes]` disables APT signature checking: whoever controls the GitHub Pages site gets root on every user's machine. Use signed repos or release checksums.
- It installs files under `/usr/local`, which Debian packaging policy forbids for packages (use `/usr/bin`, `/usr/sbin` or `/usr/libexec`, and update the polkit path and sudoers rule accordingly).
- `Depends: gnome-shell-extension-prefs` was not confirmed to exist on current Ubuntu.
- Its GNOME extension code was cut off and untested; the uploaded `hotspot-gui` has no Quick Settings switch code, so the in-app switch it describes does not exist.
- A Flatpak is not a fit: the app needs root helpers, netlink, and iptables on the host.

---

## 12. Open decisions for the owner

| Decision | Status | Notes |
|---|---|---|
| License | **MIT** (decided session 2) | |
| App ID | `local.sudar.Hotspot` | Still a placeholder. Use a reverse-DNS name you own (e.g. `io.github.<user>.Hotspot`); change in `wifi-hotspot-gui` and the `.desktop` file |
| Binary name | **`wifi-hotspot`** (renamed session 2) | Installer migrates the old `hotspot` name; Quick Settings toggle commands need manual update |
| Polkit action ID | `local.sudar.hotspot.run` | Rename together with the app ID |
| Project name / repo | `wifi-hotspot` | |
| polkit retention | `auth_admin_keep` | Convenience vs safety |
| Supported targets | Ubuntu + GNOME | Decide scope before promising more |

---

## 13. Troubleshooting guide

| Symptom | Likely cause | Check / fix |
|---|---|---|
| `RTNETLINK answers: Name not unique on network` | `ap0` has the same MAC as the client interface | Script uses MAC XOR 0x02; if the driver rejects it, try another locally administered MAC |
| `ap0` shows `unavailable` in `nmcli device` | NetworkManager manages it | Ensure `/etc/NetworkManager/conf.d/90-hotspot-ap0.conf` exists, `systemctl reload NetworkManager` |
| Phone joins, "IP configuration failed" | Firewall dropping DHCP | `HS_IN` chain present? `sudo iptables -S INPUT | head`; ufw/firewalld in use? |
| Phone joins, no internet | NAT/forwarding | `sysctl net.ipv4.ip_forward`; `sudo iptables -t nat -S`; `sudo iptables -S FORWARD | head`; is the uplink `STA`? |
| `start` says "not connected to wifi" | No Wi-Fi client connection | Connect Wi-Fi first |
| `hostapd failed: ...` / "AP did not start beaconing" | Driver/band/WPA3/DFS problem | `sudo cat /run/hotspot-hostapd.log`; `iw phy phy0 info`; try WPA2 on 2.4 GHz |
| Hotspot dies when router changes channel | AP channel is tied to STA channel | The watcher should restart it within ~12 s (session 2). If it does not, check for a "Could not restart" notification and `sudo cat /run/hotspot-hostapd.log` (DFS channels often refuse AP mode) |
| Limits have no effect | `cls_flower` missing | `tc filter show dev ap0 parent 1:`; `lsmod | grep cls_` |
| GUI says "No settings yet: run sudo hotspot init" | First run not done | `sudo hotspot init` |
| Quick Settings button out of sync | Extension not polling | Set status check `iw dev` / `type AP`, enable state sync |
| QR will not scan | Special characters or WPA3-only phone support | Test with a simple password; check payload type (`WPA` vs `SAE`) |

---

## 14. Hardware report to request from beta testers

```bash
uname -r; lsb_release -ds; gnome-shell --version
iw list | grep -A8 "valid interface combinations"
iw phy phy0 info | grep -iE "Band [0-9]|MFP|SAE|AP"
lspci -k | grep -A3 -i network   # or: lsusb for USB adapters
sudo hotspot start; iw dev; sudo cat /run/hotspot-hostapd.log
sudo iptables -S | grep HS_
```

---

## 15. Appendix A: GNOME Quick Settings extension

The project ships a native GNOME Shell extension (`wifi-hotspot@local.sudar`) that adds a toggle to
the Quick Settings panel (top-right system menu). No third-party extension is needed.

### Files

| Source | Installed to |
|---|---|
| `gnome-extension/metadata.json` | `~/.local/share/gnome-shell/extensions/wifi-hotspot@local.sudar/metadata.json` |
| `gnome-extension/extension.js` | `~/.local/share/gnome-shell/extensions/wifi-hotspot@local.sudar/extension.js` |

### How it works

1. **Toggle ON** → runs `sudo -n /usr/local/sbin/wifi-hotspot start` via `Gio.Subprocess` (async, non-blocking).
2. **Toggle OFF** → runs `sudo -n /usr/local/sbin/wifi-hotspot stop`.
3. **State poll** → every 4 s runs `iw dev` and looks for `type AP`. Sets `checked` and shows/hides the panel indicator icon accordingly.
4. **Panel icon** → `network-wireless-hotspot-symbolic` appears in the top bar while the hotspot is up.

### Requirements

- The sudoers rule from `install.sh` must be in place (`sudo -n wifi-hotspot start/stop` must not prompt).
- GNOME Shell 45–50 (ESM module format). The extension has no `prefs.js` and no GSettings schema.
- The user may need to log out and back in (or restart the GNOME Shell: Alt+F2 → `r` → Enter on X11) for the extension to load.

## 16. Appendix B: Dependencies

Runtime: `hostapd`, `dnsmasq-base` (the `dnsmasq` binary), `iw`, `iproute2` (`ip`, `tc`), `iptables` (with `iptables-restore`, `iptables-save`), `polkitd`, `pkexec`, `util-linux` (`runuser`, `setsid`), `sudo`, NetworkManager.  
GUI: `python3`, `python3-gi`, `gir1.2-gtk-4.0`, `gir1.2-adw-1` (≥ 1.5), `python3-qrcode`, `libnotify-bin`.  
Kernel: `sch_htb`, `sch_fq_codel`, `sch_ingress`, `cls_flower`, `act_police`, `xt_conntrack`.

## 17. Appendix C: Things this project already proved wrong (avoid repeating)

- Using the GNOME Settings hotspot dialog: drops Wi-Fi.
- `nmcli` AP profile on a virtual interface: NM fights hostapd, no ACL/isolation control.
- Same MAC on `ap0` and the client interface.
- `ufw allow in on ap0` (opens every port to hotspot clients). Use ports 67/53 only; the backend now does this itself.
- Passing the password as a command-line argument.
- Giving passwordless sudo to settings commands.
- Claiming a feature works without a real-hardware run.
