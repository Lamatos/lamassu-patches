#!/usr/bin/env bash
set -euo pipefail

CONF="/mnt/blockchains/bitcoin/bitcoin.conf"
OUT="/tmp/btc-funding-history-oct2025.csv"

# Ensure jq is installed
if ! command -v jq &>/dev/null; then
  echo "Installing jq..."
  DEBIAN_FRONTEND=noninteractive apt install -y jq >/dev/null
fi

# October 2025 date range (UTC)
# Oct 1 2025 00:00:00 → 1759276800
# Oct 31 2025 23:59:59 → 1761955199
START=1759276800
END=1761955199

echo "address,amount,txid,time" > "$OUT"

echo "Exporting BTC funding history for October 2025..."

bitcoin-cli -conf="$CONF" listtransactions "*" 100000 0 true \
| jq -r --argjson START "$START" --argjson END "$END" '
  .[]
  | select(.category == "receive" and .time >= $START and .time <= $END)
  | "\(.address),\(.amount),\(.txid),\(.time | strftime("%Y-%m-%d %H:%M:%S"))"
' >> "$OUT"

echo "✅ Export complete! Written to: $OUT"
