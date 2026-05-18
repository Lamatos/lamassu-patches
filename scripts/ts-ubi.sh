#!/usr/bin/env bash
set -euo pipefail

TS_VERSION="1.98.2"
TS_ARCH="amd64"
TS_DIR="tailscale_${TS_VERSION}_${TS_ARCH}"
TS_TGZ="${TS_DIR}.tgz"
TS_URL="https://pkgs.tailscale.com/stable/${TS_TGZ}"

echo "[+] Installing Tailscale ${TS_VERSION} for old Ubilinux/Debian..."

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

echo "[+] Removing stale tailscale0 interface..."
ip link delete tailscale0 2>/dev/null || true

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

echo "[+] Creating simple ts-up wrapper..."
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

if pgrep tailscaled >/dev/null; then
  echo
  echo "[✓] Tailscale installed and daemon is running."
  echo
  echo "Now run:"
  echo
  echo "sudo ts-up up --authkey YOUR_AUTHKEY --ssh"
  echo
  echo "Then check:"
  echo
  echo "ts-up status"
  echo "ts-up ip -4"
  echo
else
  echo
  echo "[!] tailscaled failed to start."
  echo "Run this to see the error:"
  echo
  echo "cat /var/log/tailscaled.log"
  echo
  exit 1
fi
