#!/usr/bin/env bash
set -euo pipefail

AUTHKEY="tskey-auth-kn1UeqnpT121CNTRL-XDV5qB8BGuLp8oEuEJQjtLbea5om1hABU"

echo "[+] Installing Tailscale repo key..."
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg \
  | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null

echo "[+] Adding Tailscale apt repo..."
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list \
  | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null

echo "[+] Updating apt..."
sudo apt-get update

echo "[+] Installing Tailscale..."
sudo apt-get install -y tailscale

echo "[+] Enabling and starting Tailscale service..."
sudo systemctl enable --now tailscaled

echo "[+] Connecting to tailnet with SSH enabled..."
sudo tailscale up --authkey "$AUTHKEY" --ssh

echo "[✓] Tailscale installed and connected successfully."
tailscale status || true
