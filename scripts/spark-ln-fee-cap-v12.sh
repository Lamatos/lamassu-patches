#!/usr/bin/env bash
set -euo pipefail

# Raise the default Spark Lightning maxFeeSats cap on an already-deployed v12 server.
# Optional override:
#   SPARK_LN_MAX_FEE_SATS=15000 bash spark-ln-fee-cap-v12.sh

SERVER_DIR="${SERVER_DIR:-/usr/lib/node_modules/lamassu-server}"
SPARK_FILE="$SERVER_DIR/lib/plugins/wallet/spark/spark.js"
NEW_MAX_FEE_SATS="${SPARK_LN_MAX_FEE_SATS:-10000}"

if [[ "$(id -u)" != "0" ]]; then
  echo "Please run as root."
  exit 1
fi

if [[ ! "$NEW_MAX_FEE_SATS" =~ ^[0-9]+$ || "$NEW_MAX_FEE_SATS" -le 0 ]]; then
  echo "SPARK_LN_MAX_FEE_SATS must be a positive integer."
  exit 1
fi

if [[ ! -f "$SPARK_FILE" ]]; then
  echo "Spark wallet plugin not found at: $SPARK_FILE"
  echo "Install the Spark v12 server integration first, or set SERVER_DIR=/path/to/lamassu-server."
  exit 1
fi

BACKUP_FILE="$SPARK_FILE.backup.$(date +%Y%m%d%H%M%S)"
cp "$SPARK_FILE" "$BACKUP_FILE"

node - "$SPARK_FILE" "$NEW_MAX_FEE_SATS" <<'NODE'
const fs = require('fs')

const sparkFile = process.argv[2]
const newMaxFeeSats = process.argv[3]
let text = fs.readFileSync(sparkFile, 'utf8')

if (!text.includes('function maxFeeSatsForAccount')) {
  throw new Error('Spark plugin does not include maxFeeSatsForAccount; refusing to patch unexpected file')
}

const pattern = /const DEFAULT_MAX_FEE_SATS = \d+/
if (!pattern.test(text)) {
  throw new Error('Could not find DEFAULT_MAX_FEE_SATS in Spark plugin')
}

text = text.replace(pattern, `const DEFAULT_MAX_FEE_SATS = ${newMaxFeeSats}`)
fs.writeFileSync(sparkFile, text)

console.log(`Spark Lightning default maxFeeSats set to ${newMaxFeeSats}.`)
NODE

node --check "$SPARK_FILE"

if command -v supervisorctl >/dev/null 2>&1; then
  supervisorctl restart lamassu-server lamassu-admin-server
elif command -v systemctl >/dev/null 2>&1; then
  systemctl restart lamassu-server || true
  systemctl restart lamassu-admin-server || true
else
  echo "Could not find supervisorctl or systemctl. Please restart Lamassu server services manually."
fi

echo "Backup saved at: $BACKUP_FILE"
echo "Spark LN fee cap hotfix installed."
