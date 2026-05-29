#!/usr/bin/env bash
set -euo pipefail

TS_VERSION="${TS_VERSION:-1.98.2}"
TS_ARCH="${TS_ARCH:-amd64}"
TS_DIR="tailscale_${TS_VERSION}_${TS_ARCH}"
TS_TGZ="${TS_DIR}.tgz"
TS_URL="https://pkgs.tailscale.com/stable/${TS_TGZ}"
TS_STATE_DIR="/var/lib/tailscale"
TS_RUN_DIR="/var/run/tailscale"
TS_SOCKET="${TS_RUN_DIR}/tailscaled.sock"
TS_STATE="${TS_STATE_DIR}/tailscaled.state"
TS_SERVICE="/etc/systemd/system/tailscaled.service"
NET_GUARD="/usr/local/sbin/upboard-network-guard"
NET_GUARD_SERVICE="/etc/systemd/system/upboard-network-guard.service"

echo "[+] Installing Tailscale ${TS_VERSION} for old Ubilinux/Debian..."

if [ "$(id -u)" -ne 0 ]; then
  echo "[!] Please run with sudo"
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "[!] systemctl is required on this board"
  exit 1
fi

download_file() {
  local url="$1"
  local out="$2"

  if command -v wget >/dev/null 2>&1; then
    wget -q --show-progress -O "$out" "$url"
    return
  fi

  if command -v curl >/dev/null 2>&1; then
    curl -fL "$url" -o "$out"
    return
  fi

  echo "[!] Need wget or curl to download Tailscale"
  exit 1
}

is_tailscale_ssh() {
  local conn="${SSH_CONNECTION:-}"
  local peer="${conn%% *}"

  case "$peer" in
    100.*|fd7a:*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

backup_state() {
  if [ ! -s "$TS_STATE" ]; then
    return
  fi

  local backup_dir="/root/tailscale-backups"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  cp -a "$TS_STATE" "${backup_dir}/tailscaled.state.${stamp}"
  echo "[+] Backed up existing Tailscale state to ${backup_dir}/tailscaled.state.${stamp}"
}

detect_wired_iface() {
  ip -o link show | awk -F': ' '$2 != "lo" && $2 !~ /^tailscale/ && $2 !~ /^docker/ && $2 !~ /^br-/ && $2 !~ /^veth/ && $2 ~ /^(en|eth)/ {print $2; exit}'
}

install_network_guard() {
  local iface="${UPBOARD_NET_IFACE:-}"

  if [[ -z "$iface" ]]; then
    iface="$(detect_wired_iface || true)"
  fi

  if [[ -z "$iface" ]]; then
    echo "[!] No wired Ethernet interface found; skipping network guard"
    return
  fi

  echo "[+] Installing UP-board Ethernet DHCP guard for ${iface}..."

  if [[ -f /etc/network/interfaces ]]; then
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    cp -a /etc/network/interfaces "/root/interfaces.backup.${stamp}"
    cat >/etc/network/interfaces <<EOF
# This file describes the network interfaces available on your system
# and how to activate them. For more information, see interfaces(5).

source /etc/network/interfaces.d/*

# The loopback network interface
auto lo
iface lo inet loopback

# The UP Board wired Ethernet interface
auto ${iface}
allow-hotplug ${iface}
iface ${iface} inet dhcp
EOF
    echo "[+] Updated /etc/network/interfaces for ${iface} (backup: /root/interfaces.backup.${stamp})"
  fi

  cat >"$NET_GUARD" <<'EOF'
#!/bin/sh
set -eu

IFACE="${UPBOARD_NET_IFACE:-}"

if [ -z "$IFACE" ]; then
  IFACE="$(ip -o link show | awk -F': ' '$2 != "lo" && $2 !~ /^tailscale/ && $2 !~ /^docker/ && $2 !~ /^br-/ && $2 !~ /^veth/ && $2 ~ /^(en|eth)/ {print $2; exit}')"
fi

if [ -z "$IFACE" ]; then
  echo "No wired Ethernet interface found" >&2
  exit 0
fi

ip link set "$IFACE" up 2>/dev/null || true

n=0
while [ "$n" -lt 20 ]; do
  if ip link show "$IFACE" | grep -q "LOWER_UP"; then
    break
  fi
  n=$((n + 1))
  sleep 1
done

if ip -4 addr show dev "$IFACE" | grep -q "inet " && ip route show default 0.0.0.0/0 | grep -q "dev $IFACE"; then
  echo "$IFACE already has IPv4 and default route"
  exit 0
fi

if pgrep -f "dhclient .*${IFACE}" >/dev/null 2>&1; then
  echo "dhclient already running for $IFACE"
else
  dhclient -4 -v "$IFACE" || dhclient "$IFACE" || true
fi

if ! ip route show default 0.0.0.0/0 | grep -q "dev $IFACE"; then
  echo "No default route after DHCP on $IFACE" >&2
  exit 1
fi
EOF
  chmod 0755 "$NET_GUARD"

  cat >"$NET_GUARD_SERVICE" <<EOF
[Unit]
Description=Ensure UP Board wired Ethernet has DHCP before dependent services
After=networking.service
Before=tailscaled.service

[Service]
Type=oneshot
ExecStart=${NET_GUARD}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable upboard-network-guard.service >/dev/null
  "$NET_GUARD" || true
}

write_service() {
  echo "[+] Installing persistent systemd service..."
  cat >"$TS_SERVICE" <<EOF
[Unit]
Description=Tailscale node agent
Documentation=https://tailscale.com/kb/
Wants=network-online.target upboard-network-guard.service
After=network-pre.target network-online.target upboard-network-guard.service

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p ${TS_RUN_DIR}
ExecStart=/usr/local/bin/tailscaled --state=${TS_STATE} --socket=${TS_SOCKET}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable tailscaled.service >/dev/null
}

cleanup_dead_runtime() {
  ip link delete tailscale0 2>/dev/null || true
  rm -f "$TS_SOCKET" /run/tailscale/tailscaled.sock
}

start_or_handoff() {
  local current_pids
  current_pids="$(pgrep -x tailscaled 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')"

  if [ -n "$current_pids" ]; then
    echo "[+] Existing tailscaled process found: ${current_pids}"

    if is_tailscale_ssh; then
      local unit_name="tailscale-handoff-$(date +%s)"
      local handoff_cmd="kill ${current_pids} 2>/dev/null || true; sleep 1; rm -f '${TS_SOCKET}' /run/tailscale/tailscaled.sock; ip link delete tailscale0 2>/dev/null || true; systemctl start tailscaled.service"

      echo "[+] Running over Tailscale SSH; scheduling safe handoff through systemd..."
      if command -v systemd-run >/dev/null 2>&1; then
        systemd-run \
          --unit="$unit_name" \
          --on-active=2s \
          /bin/bash -lc "$handoff_cmd"
      else
        nohup /bin/bash -lc "sleep 2; ${handoff_cmd}" >/tmp/tailscale-handoff.log 2>&1 &
      fi
      echo "[+] Handoff scheduled. This SSH session may reconnect briefly."
      return
    fi

    echo "[+] Restarting tailscaled under systemd..."
    kill $current_pids 2>/dev/null || true
    sleep 1
    cleanup_dead_runtime
  else
    cleanup_dead_runtime
  fi

  systemctl restart tailscaled.service
  sleep 3

  if ! systemctl is-active --quiet tailscaled.service; then
    echo "[!] tailscaled.service did not start"
    systemctl status tailscaled.service --no-pager -l || true
    exit 1
  fi

  if /usr/local/bin/tailscale --socket="$TS_SOCKET" status --self >/dev/null 2>&1; then
    echo "[+] Tailscale is running and authenticated."
  else
    echo "[+] Tailscale daemon is running. If this is a fresh install, run:"
    echo "    ts-up up"
  fi
}

mkdir -p "$TS_STATE_DIR" "$TS_RUN_DIR" /usr/local/bin
backup_state
install_network_guard

cd /tmp
rm -rf "$TS_DIR" "$TS_TGZ"

echo "[+] Downloading Tailscale ${TS_VERSION}..."
download_file "$TS_URL" "$TS_TGZ"

echo "[+] Extracting..."
tar xzf "$TS_TGZ"

echo "[+] Installing static binaries..."
install -m 0755 "$TS_DIR/tailscale" /usr/local/bin/tailscale.new
install -m 0755 "$TS_DIR/tailscaled" /usr/local/bin/tailscaled.new
mv -f /usr/local/bin/tailscale.new /usr/local/bin/tailscale
mv -f /usr/local/bin/tailscaled.new /usr/local/bin/tailscaled

echo "[+] Creating ts-up wrapper..."
cat >/usr/local/bin/ts-up <<'EOF'
#!/usr/bin/env bash
/usr/local/bin/tailscale \
  --socket=/var/run/tailscale/tailscaled.sock \
  "$@"
EOF
chmod +x /usr/local/bin/ts-up

write_service

if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify "$TS_SERVICE" >/dev/null 2>&1 || true
fi

start_or_handoff

echo
echo "[OK] Tailscale installed with persistent boot service."
echo "[OK] Service: tailscaled.service"
echo "[OK] CLI: ts-up status"
echo
