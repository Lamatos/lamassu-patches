#!/usr/bin/env bash
set -euo pipefail

TS_VERSION="1.90.6"
TS_ARCH="amd64"
TS_DIR="tailscale_${TS_VERSION}_${TS_ARCH}"
TS_TGZ="${TS_DIR}.tgz"
TS_URL="https://pkgs.tailscale.com/stable/${TS_TGZ}"

echo "[+] Installing Tailscale static binary for old Debian/Ubilinux..."

if [ "$(id -u)" -ne 0 ]; then
  echo "[!] Please run as root or with sudo:"
  echo "    sudo bash $0"
  exit 1
fi

mkdir -p /var/lib/tailscale
mkdir -p /usr/local/bin
cd /tmp

echo "[+] Downloading Tailscale ${TS_VERSION}..."
rm -rf "$TS_DIR" "$TS_TGZ"
wget -q --show-progress "$TS_URL"

echo "[+] Extracting..."
tar xzf "$TS_TGZ"

echo "[+] Installing binaries..."
cp "$TS_DIR/tailscale" /usr/local/bin/tailscale
cp "$TS_DIR/tailscaled" /usr/local/bin/tailscaled
chmod +x /usr/local/bin/tailscale /usr/local/bin/tailscaled

echo "[+] Stopping old tailscaled if running..."
pkill tailscaled 2>/dev/null || true

echo "[+] Starting tailscaled..."
nohup /usr/local/bin/tailscaled \
  --state=/var/lib/tailscale/tailscaled.state \
  >/var/log/tailscaled.log 2>&1 &

sleep 3

echo
echo "[✓] Tailscale installed."
echo
echo "Now run this with your auth key:"
echo
echo "  sudo /usr/local/bin/tailscale up --authkey YOUR_AUTHKEY --ssh"
echo
echo "Then check status with:"
echo
echo "  /usr/local/bin/tailscale status"
echo "  /usr/local/bin/tailscale ip -4"
echo
