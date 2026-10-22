#!/bin/sh
set -eu
KEY="tskey-auth-ksKV8MqxtC21CNTRL-2ZdrphrNyF4rV4vC46CyF4ncdB6G3MJtc"
k=${KEY:-${TS_AUTHKEY:-${1:?authkey}}}
apt-get update
apt-get install -y curl openssh-server
curl -fsSL https://tailscale.com/install.sh -o /tmp/ts.sh
sh /tmp/ts.sh
systemctl enable --now ssh
tailscale up --auth-key="$k" --ssh
