#!/bin/bash

# Configurable path to bitcoin.conf
CONF_PATH="/mnt/blockchains/bitcoin/bitcoin.conf"
OUTPUT_FILE="wallet-transactions.csv"

# Check if jq is installed
if ! command -v jq &> /dev/null; then
  echo "❌ 'jq' is required but not installed. Please install jq and try again."
  exit 1
fi

echo "Exporting wallet transactions to $OUTPUT_FILE..."

# Header
echo "txid,category,amount,blockheight,blocktime,confirmations" > "$OUTPUT_FILE"

# Query and convert to CSV
bitcoin-cli -conf="$CONF_PATH" listtransactions "*" 1000000 0 true \
| jq -r '.[] | [
    .txid,
    .category,
    (.amount // 0),
    (.blockheight // 0),
    (.blocktime // 0),
    (.confirmations // 0)
  ] | @csv' >> "$OUTPUT_FILE"

echo "✅ Done! Saved to $OUTPUT_FILE"
