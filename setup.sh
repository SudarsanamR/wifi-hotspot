#!/bin/bash
# Add the wifi-hotspot APT repository.
# Usage:  curl -fsSL https://sudarsanamr.github.io/wifi-hotspot/setup.sh | sudo bash
set -e

REPO="https://sudarsanamr.github.io/wifi-hotspot"
KEYRING="/usr/share/keyrings/wifi-hotspot.gpg"
LIST="/etc/apt/sources.list.d/wifi-hotspot.list"

echo "Adding wifi-hotspot APT repository..."

# Download and install the signing key
curl -fsSL "$REPO/gpg.key" | gpg --dearmor -o "$KEYRING"
chmod 644 "$KEYRING"

# Add the repository
echo "deb [signed-by=$KEYRING] $REPO stable main" > "$LIST"

# Update package lists
apt update -o Dir::Etc::sourcelist="$LIST" -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0" >/dev/null 2>&1

echo ""
echo "Done! Now run:"
echo "  sudo apt install wifi-hotspot"
