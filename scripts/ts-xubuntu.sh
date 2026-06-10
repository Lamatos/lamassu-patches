#!/bin/sh
set -eu
KEY=""
k=${KEY:-${TS_AUTHKEY:-${1:?authkey}}}
apt-get update
apt-get install -y curl openssh-server
curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now ssh
tailscale up --auth-key="$k" --ssh