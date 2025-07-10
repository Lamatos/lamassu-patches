#!/bin/bash

set -e

# File paths
BASE_GETH="/usr/lib/node_modules/lamassu-server/lib/plugins/wallet/geth/base.js"
BASE_TRON="/usr/lib/node_modules/lamassu-server/lib/plugins/wallet/tron/base.js"
PLUGINS_JS="/usr/lib/node_modules/lamassu-server/lib/plugins.js"

# Backup originals
cp "$BASE_GETH" "$BASE_GETH.bak"
cp "$BASE_TRON" "$BASE_TRON.bak"
cp "$PLUGINS_JS" "$PLUGINS_JS.bak"

echo "Patching geth/base.js..."

# Patch geth/base.js
sed -i '/if (r\.eq(0)) return/a\      if (cryptoCode !== '\''ETH'\'') return' "$BASE_GETH"
sed -i 's/\bconfirmed\.gte(/BN(confirmed).gte(/g' "$BASE_GETH"
sed -i 's/\bpending\.gte(/BN(pending).gte(/g' "$BASE_GETH"
sed -i 's/\bpending\.gt(/BN(pending).gt(/g' "$BASE_GETH"

echo "Patching tron/base.js..."

# Patch tron/base.js (apply same logic as geth)
sed -i '/if (r\.eq(0)) return/a\    if (cryptoCode !== '\''TRX'\'' \&\& !coins.utils.isTrc20Token(cryptoCode)) return' "$BASE_TRON"
sed -i 's/\bconfirmed\.gte(/BN(confirmed).gte(/g' "$BASE_TRON"
sed -i 's/\bconfirmed\.gt(/BN(confirmed).gt(/g' "$BASE_TRON"

echo "Patching plugins.js..."

# Patch plugins.js
sed -i 's/isCashInOnly: Boolean(cryptoRec.isCashinOnly)/isCashInOnly: false/' "$PLUGINS_JS"

echo "Restarting services..."

# Restart Lamassu services
supervisorctl restart lamassu-server lamassu-admin-server

echo "Patch complete. Backups created:"
echo "  $BASE_GETH.bak"
echo "  $BASE_TRON.bak"
echo "  $PLUGINS_JS.bak"
