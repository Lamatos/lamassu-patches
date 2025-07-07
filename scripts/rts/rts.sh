#!/bin/bash
set -e

curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled
sudo tailscale up --authkey tskey-auth-kdDR4iAnGW11CNTRL-nfTnjZuv5oVmAe5zZZuToVzZkcqmpAhSP --ssh --hostname lamassu-$(hostname)
