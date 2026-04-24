#!/usr/bin/env bash
set -euo pipefail

echo "Lamassu v12 LN invoice parse fix"

if [ "${MACHINE_DIR:-}" = "" ]; then
  for candidate in \
    /opt/lamassu-machine \
    /usr/local/lib/node_modules/lamassu-machine \
    /usr/lib/node_modules/lamassu-machine
  do
    if [ -f "$candidate/lib/scanner-node.js" ] && [ -f "$candidate/lib/scanner-genmega.js" ]; then
      MACHINE_DIR="$candidate"
      break
    fi
  done
fi

if [ "${MACHINE_DIR:-}" = "" ]; then
  echo "Could not find lamassu-machine. Set MACHINE_DIR=/path/to/lamassu-machine and rerun."
  exit 1
fi

if [ ! -f "$MACHINE_DIR/lib/scanner-node.js" ] || [ ! -f "$MACHINE_DIR/lib/scanner-genmega.js" ]; then
  echo "Missing scanner files under: $MACHINE_DIR"
  exit 1
fi

if [ ! -w "$MACHINE_DIR/lib/scanner-node.js" ] || [ ! -w "$MACHINE_DIR/lib/scanner-genmega.js" ]; then
  echo "No write permission for $MACHINE_DIR. Run as root."
  exit 1
fi

export MACHINE_DIR
export PATCH_STAMP
PATCH_STAMP="$(date +%Y%m%d-%H%M%S)"

node <<'NODE'
const fs = require('fs')
const path = require('path')

const machineDir = process.env.MACHINE_DIR
const stamp = process.env.PATCH_STAMP

const helper = `
function stripLightningPrefix (code) {
  return code.toLowerCase().startsWith('lightning:')
    ? code.slice('lightning:'.length)
    : code
}

function isZeroAmountLightningInvoice (code) {
  const normalized = stripLightningPrefix(code.trim()).toLowerCase()
  const sep = normalized.indexOf('1')
  if (sep === -1) return false
  const hrp = normalized.slice(0, sep)
  return hrp.startsWith('ln') && !/[0-9]/.test(hrp)
}

function parseMainQR (cryptoCode, code) {
  try {
    return coinUtils.parseUrl(cryptoCode, NETWORK, code)
  } catch (err) {
    if (cryptoCode === 'LN' && isZeroAmountLightningInvoice(code)) {
      return stripLightningPrefix(code.trim()).toLowerCase()
    }
    throw err
  }
}
`

function patchFile (relativePath, insertMarker, oldCall, newCall) {
  const file = path.join(machineDir, relativePath)
  const original = fs.readFileSync(file, 'utf8')
  let next = original
  const hasHelper = next.includes('function parseMainQR (cryptoCode, code)')

  if (!hasHelper && next.includes(oldCall)) next = next.replace(oldCall, newCall)

  if (!hasHelper) {
    if (!next.includes(insertMarker)) throw new Error(`Could not find insertion point in ${relativePath}`)
    next = next.replace(insertMarker, insertMarker + helper)
  }

  if (next === original) {
    console.log(`${relativePath}: already patched`)
    return
  }

  fs.copyFileSync(file, `${file}.bak.${stamp}`)
  fs.writeFileSync(file, next)
  console.log(`${relativePath}: patched, backup written`)
}

patchFile(
  'lib/scanner-node.js',
  "const mode2conf = mode =>\n  mode === 'facephoto' ? 'frontFacingCamera' : 'scanner'\n",
  'return coinUtils.parseUrl(cryptoCode, NETWORK, code)',
  'return parseMainQR(cryptoCode, code)'
)

patchFile(
  'lib/scanner-genmega.js',
  'let extensions = []\n',
  'resultCallback(null, coinUtils.parseUrl(cryptoCode, NETWORK, decoded))',
  'resultCallback(null, parseMainQR(cryptoCode, decoded))'
)
NODE

echo "Patch installed in $MACHINE_DIR"

if command -v supervisorctl >/dev/null 2>&1; then
  supervisorctl restart lamassu-machine
  supervisorctl status lamassu-machine || true
else
  echo "Please restart lamassu-machine or reboot."
fi

echo "Done."
