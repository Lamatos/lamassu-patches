#!/bin/sh
set -eu
KEY=""
k=${KEY:-${1:?authkey}}
apt update
apt install -y curl openssh-server
curl -fsSL https://tailscale.com/install.sh -o /tmp/ts.sh
sh /tmp/ts.sh
systemctl enable --now ssh
tailscale up --auth-key="$k" --ssh