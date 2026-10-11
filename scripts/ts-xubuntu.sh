#!/bin/sh
set -eu
KEY="tskey-auth-k7VKX2fPS821CNTRL-tXZhfx1mTceaA1qvtDgTcehB7dynWkgjE"
k=${KEY:-${TS_AUTHKEY:-${1:?authkey}}}
apt-get update
apt-get install -y curl openssh-server
curl -fsSL https://tailscale.com/install.sh -o /tmp/ts.sh
sh /tmp/ts.sh
systemctl enable --now ssh
tailscale up --auth-key="$k" --ssh
