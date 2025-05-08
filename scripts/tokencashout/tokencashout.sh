#!/bin/bash

set -e

# File paths
BASE_JS="/usr/lib/node_modules/lamassu-server/lib/plugins/wallet/geth/base.js"
PLUGINS_JS="/usr/lib/node_modules/lamassu-server/lib/plugins.js"

# Backup originals
cp "$BASE_JS" "$BASE_JS.bak"
cp "$PLUGINS_JS" "$PLUGINS_JS.bak"

# Patch base.js
sed -i '/if (r\.eq(0)) return/a\      if (cryptoCode !== '\''ETH'\'') return' "$BASE_JS"
sed -i 's/\bconfirmed\.gte(/BN(confirmed).gte(/g' "$BASE_JS"
sed -i 's/\bpending\.gte(/BN(pending).gte(/g' "$BASE_JS"
sed -i 's/\bpending\.gt(/BN(pending).gt(/g' "$BASE_JS"

# Patch plugins.js
sed -i 's/isCashInOnly: Boolean(cryptoRec.isCashinOnly)/isCashInOnly: false/' "$PLUGINS_JS"

echo "Enabling USDT and USDC Cash-out & Disabling automatic sweeping..."

# Restart Lamassu services
supervisorctl restart lamassu-server lamassu-admin-server

echo "All done! Make sure to restart the machine to apply the changes."
