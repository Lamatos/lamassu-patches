#!/bin/sh
set -eu
k=${TS_AUTHKEY:-${1:?usage: ts-xubuntu.sh <tailscale-auth-key>}}
apt-get update
apt-get install -y curl openssh-server
curl -fsSL https://tailscale.com/install.sh -o /tmp/ts.sh
sh /tmp/ts.sh
systemctl enable --now ssh
tailscale up --auth-key="$k" --ssh
