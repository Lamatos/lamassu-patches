#!/bin/bash
set -e

curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled
sudo tailscale up --authkey tskey-auth-kw7zRomRL211CNTRL-6kTXJvfuSt251QnMw5GHu2ro2prnFP4f --ssh --hostname lamassu-$(hostname)
