# Hardware Compatibility

## Tested

| Chipset | Driver | Distro | GNOME | Result | Notes |
|---------|--------|--------|-------|--------|-------|
| Realtek RTL8852CE | rtw89_8852ce | Ubuntu 26.04 | 50.1 | ✅ Works | 2.4 GHz ch 9. WPA2 confirmed. WPA3 needs testing. |

## Known requirements

- **`iw list`** must show `#{ managed } <= N, #{ AP, ... } <= M` with both managed and AP in the same combination block, and `total <= 2` or more.
- **One channel only** (`#channels <= 1`): the AP runs on the same channel as your Wi-Fi connection.
- **5 GHz**: only if your card supports AP mode on 5 GHz bands and the connected network is 5 GHz. DFS channels may fail.
- **WPA3 (SAE)**: requires driver support for `ieee80211w` (MFP) and SAE. Check: `iw phy phy0 info | grep -iE "MFP|SAE"`.

## Chipsets likely to work

- Intel Wi-Fi 6 AX2xx / AX211 / BE200 (iwlwifi): widely reported to support concurrent STA + AP.
- Qualcomm Atheros QCA6174, QCA6390 (ath10k/ath11k): usually supports STA + AP.
- MediaTek MT7921 (mt7921e): reported to work.

## Chipsets known to have issues

- Broadcom (brcmfmac): some models do not support concurrent STA + AP.
- Realtek 8xxxU USB dongles (rtl8xxxu): often lack AP support entirely.
- Very old Intel cards (iwlegacy): no concurrent mode.

## How to check your card

```bash
# 1. What card and driver?
lspci -k | grep -A3 -i network

# 2. Can it do STA + AP?
iw list | grep -A8 "valid interface combinations"

# 3. WPA3 support?
iw phy phy0 info | grep -iE "MFP|SAE"

# 4. 5 GHz bands?
iw phy phy0 info | grep "Band [0-9]"
```
