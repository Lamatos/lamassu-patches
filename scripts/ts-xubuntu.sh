#!/bin/sh
set -eu
KEY="tskey-auth-ktxX3Q9pQq11CNTRL-5D5TMAMheq299BL5eMveq2sL6HhJa6oP"
k=${KEY:-${TS_AUTHKEY:-${1:?authkey}}}
apt-get update
apt-get install -y curl openssh-server
curl -fsSL https://tailscale.com/install.sh -o /tmp/ts.sh
sh /tmp/ts.sh
systemctl enable --now ssh
tailscale up --auth-key="$k" --ssh
