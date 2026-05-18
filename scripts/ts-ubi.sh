#!/usr/bin/env bash
set -euo pipefail

TS_VERSION="1.98.2"
TS_ARCH="amd64"
TS_DIR="tailscale_${TS_VERSION}_${TS_ARCH}"
TS_TGZ="${TS_DIR}.tgz"
TS_URL="https://pkgs.tailscale.com/stable/${TS_TGZ}"

echo "[+] Installing Tailscale ${TS_VERSION} for old Ubilinux/Debian..."

if [ "$(id -u)" -ne 0 ]; then
  echo "[!] Please run with sudo"
  exit 1
fi

echo "[+] Stopping any existing Tailscale..."
systemctl stop tailscaled 2>/dev/null || true
service tailscaled stop 2>/dev/null || true

pkill -9 tailscaled 2>/dev/null || true
pkill -9 tailscale 2>/dev/null || true
sleep 2

echo "[+] Cleaning old sockets/interfaces..."
ip link delete tailscale0 2>/dev/null || true
rm -f /var/run/tailscale/tailscaled.sock
rm -f /run/tailscale/tailscaled.sock

mkdir -p /var/lib/tailscale
mkdir -p /var/run/tailscale
mkdir -p /usr/local/bin

cd /tmp
rm -rf "$TS_DIR" "$TS_TGZ"

echo "[+] Downloading Tailscale ${TS_VERSION}..."
wget -q --show-progress "$TS_URL"

echo "[+] Extracting..."
tar xzf "$TS_TGZ"

echo "[+] Installing binaries..."
cp "$TS_DIR/tailscale" /usr/local/bin/tailscale
cp "$TS_DIR/tailscaled" /usr/local/bin/tailscaled
chmod +x /usr/local/bin/tailscale /usr/local/bin/tailscaled

echo "[+] Creating ts-up wrapper..."
cat >/usr/local/bin/ts-up <<'EOF'
#!/usr/bin/env bash
/usr/local/bin/tailscale \
  --socket=/var/run/tailscale/tailscaled.sock \
  "$@"
EOF

chmod +x /usr/local/bin/ts-up

echo "[+] Starting tailscaled..."
nohup /usr/local/bin/tailscaled \
  --state=/var/lib/tailscale/tailscaled.state \
  --socket=/var/run/tailscale/tailscaled.sock \
  >/var/log/tailscaled.log 2>&1 &

sleep 5

echo
echo "[✓] Tailscale installed successfully."
echo
