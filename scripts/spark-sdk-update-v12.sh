#!/usr/bin/env bash
set -euo pipefail

SERVER_DIR="${SERVER_DIR:-/usr/lib/node_modules/lamassu-server}"
SDK_DIR="${SPARK_SDK_DIR:-$SERVER_DIR/spark-sdk-install}"
SPARK_SDK_VERSION="${SPARK_SDK_VERSION:-0.8.1}"
BOLT11_VERSION="${BOLT11_VERSION:-1.5.1}"
RESTART_SERVICES="${RESTART_SERVICES:-true}"

if [[ "$(id -u)" != "0" ]]; then
  echo "Please run as root."
  exit 1
fi

if [[ ! -d "$SERVER_DIR" ]]; then
  echo "Lamassu server not found at $SERVER_DIR"
  echo "Set SERVER_DIR=/path/to/lamassu-server if this install uses a custom path."
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "npm is required but was not found."
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "node is required but was not found."
  exit 1
fi

node <<'NODE'
const major = Number(process.versions.node.split('.')[0])
if (!Number.isFinite(major) || major < 18) {
  console.error(`Spark SDK 0.8.1 requires Node.js >=18. Current Node.js is ${process.versions.node}.`)
  console.error('Upgrade the Lamassu server Node.js runtime before running this script.')
  process.exit(1)
}
NODE

mkdir -p "$SDK_DIR"

BACKUP_DIR="$SDK_DIR/backup-before-spark-sdk-$SPARK_SDK_VERSION-$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR"
for file in package.json package-lock.json npm-shrinkwrap.json; do
  if [[ -f "$SDK_DIR/$file" ]]; then
    cp "$SDK_DIR/$file" "$BACKUP_DIR/$file"
  fi
done

echo "Installing Spark SDK $SPARK_SDK_VERSION into $SDK_DIR..."
npm install --prefix "$SDK_DIR" \
  "@buildonspark/spark-sdk@$SPARK_SDK_VERSION" \
  "@lamassu/bolt11@$BOLT11_VERSION"

node - "$SDK_DIR" "$SPARK_SDK_VERSION" <<'NODE'
const fs = require('fs')
const path = require('path')
const { pathToFileURL } = require('url')

const sdkDir = process.argv[2]
const expectedVersion = process.argv[3]
const packageJson = path.join(
  sdkDir,
  'node_modules',
  '@buildonspark',
  'spark-sdk',
  'package.json',
)
const nodeEntrypoint = path.join(
  sdkDir,
  'node_modules',
  '@buildonspark',
  'spark-sdk',
  'dist',
  'index.node.js',
)

if (!fs.existsSync(packageJson)) {
  throw new Error(`Spark SDK package.json not found at ${packageJson}`)
}

const installed = JSON.parse(fs.readFileSync(packageJson, 'utf8')).version
if (installed !== expectedVersion) {
  throw new Error(`Expected Spark SDK ${expectedVersion}, found ${installed}`)
}

if (!fs.existsSync(nodeEntrypoint)) {
  throw new Error(`Spark SDK node entrypoint missing: ${nodeEntrypoint}`)
}

import(pathToFileURL(nodeEntrypoint).href).then(mod => {
  if (!mod.SparkWallet || typeof mod.SparkWallet.initialize !== 'function') {
    throw new Error('Spark SDK does not export SparkWallet.initialize')
  }

  console.log(`Verified @buildonspark/spark-sdk ${installed}`)
}).catch(err => {
  console.error(err)
  process.exit(1)
})
NODE

SPARK_PLUGIN="$SERVER_DIR/lib/plugins/wallet/spark/spark.js"
if [[ -f "$SPARK_PLUGIN" ]]; then
  node --check "$SPARK_PLUGIN"
fi

if [[ "$RESTART_SERVICES" == "true" ]]; then
  if command -v supervisorctl >/dev/null 2>&1; then
    supervisorctl restart lamassu-server lamassu-admin-server
  elif command -v systemctl >/dev/null 2>&1; then
    systemctl restart lamassu-server || true
    systemctl restart lamassu-admin-server || true
  else
    echo "Could not find supervisorctl or systemctl. Restart Lamassu server services manually."
  fi
else
  echo "RESTART_SERVICES=false; skipping Lamassu service restart."
fi

echo "Backup directory: $BACKUP_DIR"
echo "Spark SDK update complete."
