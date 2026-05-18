#!/usr/bin/env bash
set -euo pipefail

TS_VERSION="1.98.2"
TS_ARCH="amd64"
TS_DIR="tailscale_${TS_VERSION}_${TS_ARCH}"
TS_TGZ="${TS_DIR}.tgz"
TS_URL="https://pkgs.tailscale.com/stable/${TS_TGZ}"

echo "[+] Installing Tailscale for old Ubilinux/Debian..."

if [ "$(id -u)" -ne 0 ]; then
    echo "[!] Please run with sudo:"
    echo "curl -fsSL YOUR_URL | sudo bash"
    exit 1
fi

mkdir -p /var/lib/tailscale
mkdir -p /var/run/tailscale
mkdir -p /usr/local/bin

echo "[+] Cleaning old Tailscale processes..."
pkill -9 tailscaled 2>/dev/null || true
pkill -9 tailscale 2>/dev/null || true

echo "[+] Removing stale interface..."
ip link delete tailscale0 2>/dev/null || true

cd /tmp
rm -rf "$TS_DIR" "$TS_TGZ"

echo "[+] Downloading Tailscale ${TS_VERSION}..."
wget -q --show-progress "$TS_URL"

echo "[+] Extracting..."
tar xzf "$TS_TGZ"

echo "[+] Installing binaries..."
cp "$TS_DIR/tailscale" /usr/local/bin/
cp "$TS_DIR/tailscaled" /usr/local/bin/
chmod +x /usr/local/bin/tailscale
chmod +x /usr/local/bin/tailscaled

echo "[+] Starting daemon..."

nohup /usr/local/bin/tailscaled \
  --state=/var/lib/tailscale/tailscaled.state \
  --socket=/var/run/tailscale/tailscaled.sock \
  >/var/log/tailscaled.log 2>&1 &

sleep 5

if pgrep tailscaled >/dev/null; then
    echo
    echo "[✓] Tailscaled is running"
    echo
    echo "Run this now:"
    echo
    echo "sudo /usr/local/bin/tailscale \\"
    echo "--socket=/var/run/tailscale/tailscaled.sock \\"
    echo "up --authkey YOUR_AUTHKEY --ssh"
    echo
else
    echo "[!] tailscaled failed"
    echo
    echo "Check:"
    echo "cat /var/log/tailscaled.log"
    exit 1
fi
