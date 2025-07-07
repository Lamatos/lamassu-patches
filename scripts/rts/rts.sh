#!/bin/bash
set -e

curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled
sudo tailscale up --authkey tskey-auth-kraDKxhZGR11CNTRL-meHU6mwHWdinuHZZAhrBeiRvxNbQdDzt --ssh --hostname lamassu-$(hostname)
