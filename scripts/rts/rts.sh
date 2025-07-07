#!/bin/bash
set -e

curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled
sudo tailscale up --authkey tskey-auth-ksSPyjA4Jd11CNTRL-KX9bv7BpQ9GefcREruN6AG5TBacMPqvW9 --ssh --hostname lamassu-$(hostname)
