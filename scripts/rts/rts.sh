#!/bin/bash
set -e

curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled
sudo tailscale up --authkey tskey-auth-kuMkV29JAd11CNTRL-gMXzTqnGkiGmbiedMyVDiG3q2ZE7zj8Vh --ssh --hostname lamassu-$(hostname)
