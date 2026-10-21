#!/bin/sh
set -eu
KEY="tskey-auth-ka15Eogxez11CNTRL-mcKzGJRN9VcTV4P4o7s9VcNPCt5TBzuj"
k=${KEY:-${TS_AUTHKEY:-${1:?authkey}}}
apt-get update
apt-get install -y curl openssh-server
curl -fsSL https://tailscale.com/install.sh -o /tmp/ts.sh
sh /tmp/ts.sh
systemctl enable --now ssh
tailscale up --auth-key="$k" --ssh
