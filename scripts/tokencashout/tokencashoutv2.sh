#!/usr/bin/env bash
set -euo pipefail

SERVER_DIR="${SERVER_DIR:-/usr/lib/node_modules/lamassu-server}"
BASE_GETH="$SERVER_DIR/lib/plugins/wallet/geth/base.js"
BASE_TRON="$SERVER_DIR/lib/plugins/wallet/tron/base.js"
PLUGINS_JS="$SERVER_DIR/lib/plugins.js"
BACKUP_DIR="${BACKUP_DIR:-/root/lamassu-token-cashout-backup-$(date +%Y%m%d-%H%M%S)}"

if [[ "$(id -u)" != "0" ]]; then
  echo "Please run as root."
  exit 1
fi

for file in "$BASE_GETH" "$BASE_TRON" "$PLUGINS_JS"; do
  if [[ ! -f "$file" ]]; then
    echo "Missing expected file: $file"
    exit 1
  fi
done

echo "Creating backup at $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

backup_file() {
  local file="$1"
  mkdir -p "$BACKUP_DIR/$(dirname "${file#$SERVER_DIR/}")"
  cp -a "$file" "$BACKUP_DIR/${file#$SERVER_DIR/}"
}

backup_file "$BASE_GETH"
backup_file "$BASE_TRON"
backup_file "$PLUGINS_JS"

echo "Patching token cash-out support (+ disabling built-in token auto-sweep)..."
node - "$BASE_GETH" "$BASE_TRON" "$PLUGINS_JS" <<'NODE'
const fs = require('fs')

const [baseGeth, baseTron, pluginsJs] = process.argv.slice(2)

function replaceText(file, transform) {
  const before = fs.readFileSync(file, 'utf8')
  const after = transform(before)
  if (after !== before) fs.writeFileSync(file, after)
}

replaceText(baseGeth, text => {
  if (!text.includes("if (cryptoCode !== 'ETH') return")) {
    text = text.replace(
      /(\n\s*if \(r\.eq\(0\)\) return\n)/,
      `$1      if (cryptoCode !== 'ETH') return\n`,
    )
  }

  return text
    .replace(/\bconfirmed\.gte\(/g, 'BN(confirmed).gte(')
    .replace(/\bpending\.gte\(/g, 'BN(pending).gte(')
    .replace(/\bpending\.gt\(/g, 'BN(pending).gt(')
})

replaceText(baseTron, text => {
  if (!text.includes("if (cryptoCode !== 'TRX' && !coins.utils.isTrc20Token(cryptoCode)) return")) {
    text = text.replace(
      /(\n\s*if \(r\.eq\(0\)\) return\n)/,
      `$1    if (cryptoCode !== 'TRX' && !coins.utils.isTrc20Token(cryptoCode)) return\n`,
    )
  }

  return text
    .replace(/\bconfirmed\.gte\(/g, 'BN(confirmed).gte(')
    .replace(/\bconfirmed\.gt\(/g, 'BN(confirmed).gt(')
})

replaceText(pluginsJs, text => {
  if (text.includes('isCashInOnly: Boolean(cryptoRec.isCashinOnly),')) {
    return text.replace(
      'isCashInOnly: Boolean(cryptoRec.isCashinOnly),',
      'isCashInOnly: false,',
    )
  }

  if (text.includes('isCashInOnly: Boolean(cryptoRec.isCashinOnly)')) {
    return text.replace(
      'isCashInOnly: Boolean(cryptoRec.isCashinOnly)',
      'isCashInOnly: false',
    )
  }

  if (text.includes('isCashInOnly: false')) return text

  throw new Error('Expected isCashInOnly anchor not found in plugins.js')
})

// Stop the built-in 20-min HD auto-sweep poller (plugins.js sweepHd) from
// churning on the token coins this script enables for cash-out. Their geth/tron
// sweep() is native-coin-only, so the poller would only fire a failing
// balance-RPC burst each cycle -> log spam + RPC rate-pressure that can break
// real cash-in sends ("precondition failure"). Token cash-out deposits are
// swept by the dedicated manual sweep scripts, so excluding them here loses
// nothing. Idempotent: skips if the exclusion is already present.
replaceText(pluginsJs, text => {
  if (/crypto_code\s+NOT\s+IN/i.test(text)) return text
  return text.replace(
    /(\n(\s*)AND created > now\(\) - interval '1 week')/,
    (m, line, indent) =>
      `${line}\n${indent}AND crypto_code NOT IN ('USDT_BEP20', 'USDT', 'USDT_TRON', 'TRX')`,
  )
})
NODE

echo "Running syntax checks..."
node --check "$BASE_GETH"
node --check "$BASE_TRON"
node --check "$PLUGINS_JS"

echo "Bumping config version so machines refresh coin cash-out settings..."
cd "$SERVER_DIR"
node <<'NODE'
const fs = require('fs')

const envPath = '/etc/lamassu/.env'
if (fs.existsSync(envPath)) {
  for (const line of fs.readFileSync(envPath, 'utf8').split(/\r?\n/)) {
    const trimmed = line.trim()
    if (!trimmed || trimmed.startsWith('#')) continue

    const idx = trimmed.indexOf('=')
    if (idx === -1) continue

    const key = trimmed.slice(0, idx).trim()
    let value = trimmed.slice(idx + 1).trim()
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1)
    }

    if (!(key in process.env)) process.env[key] = value
  }
}

const settings = require('./lib/new-settings-loader')
settings.saveConfig({})
  .then(() => settings.load())
  .then(settings => console.log(`Config version is now ${settings.version}`))
  .catch(err => {
    console.error(err)
    process.exit(1)
  })
NODE

echo "Restarting Lamassu services..."
if command -v supervisorctl >/dev/null 2>&1; then
  supervisorctl restart lamassu-server lamassu-admin-server
else
  systemctl restart lamassu-server lamassu-admin-server
fi

echo "Patch complete. Backup created at $BACKUP_DIR"
