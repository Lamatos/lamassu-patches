#!/usr/bin/env bash
set -euo pipefail

MACHINE_DIR="${MACHINE_DIR:-}"
USDB_TOKEN_IDENTIFIER="${SPARK_USDB_TOKEN_IDENTIFIER:-btkn1xgrvjwey5ngcagvap2dzzvsy4uk8ua9x69k82dwvt5e7ef9drm9qztux87}"
INSTALL_MOCK_SPARK_QR="${INSTALL_MOCK_SPARK_QR:-false}"

if [[ -z "$MACHINE_DIR" ]]; then
  if [[ -d "$PWD/node_modules/@lamassu/coins/dist" && -d "$PWD/lib" ]]; then
    MACHINE_DIR="$PWD"
  elif [[ -d /home/lamatos/lamassu-machine ]]; then
    MACHINE_DIR=/home/lamatos/lamassu-machine
  elif [[ -d /home/lamatos/stack/lamassu-machine ]]; then
    MACHINE_DIR=/home/lamatos/stack/lamassu-machine
  elif [[ -d /home/lamassu/lamassu-machine ]]; then
    MACHINE_DIR=/home/lamassu/lamassu-machine
  else
    echo "Lamassu machine folder not found."
    echo "Run this script from inside lamassu-machine, or set MACHINE_DIR=/path/to/lamassu-machine"
    exit 1
  fi
fi

if [[ ! -d "$MACHINE_DIR" ]]; then
  echo "Lamassu machine folder not found: $MACHINE_DIR"
  exit 1
fi

COINS_DIR="$MACHINE_DIR/node_modules/@lamassu/coins/dist"
BRAIN_FILE="$MACHINE_DIR/lib/brain.js"
APP_FILE="$MACHINE_DIR/ui/js/app.js"
SCANNER_FILE="$MACHINE_DIR/lib/mocks/scanner.js"
DEVICE_CONFIG="$MACHINE_DIR/device_config.json"
if [[ ! -d "$COINS_DIR" ]]; then
  echo "@lamassu/coins not found under $MACHINE_DIR/node_modules"
  exit 1
fi

node - "$COINS_DIR" "$USDB_TOKEN_IDENTIFIER" <<'NODE'
const fs = require('fs')
const path = require('path')

const coinsDir = process.argv[2]
const usdbTokenIdentifier = process.argv[3]

function replaceOnce(file, search, replacement) {
  let text = fs.readFileSync(file, 'utf8')
  if (text.includes(replacement)) return
  if (!text.includes(search)) {
    throw new Error(`Patch anchor not found in ${file}: ${search.slice(0, 80)}`)
  }
  text = text.replace(search, replacement)
  fs.writeFileSync(file, text)
}

const consts = path.join(coinsDir, 'config', 'consts.js')
const utils = path.join(coinsDir, 'utils.js')

replaceOnce(
  consts,
  '    CryptoCode["USDC"] = "USDC";\n',
  '    CryptoCode["USDC"] = "USDC";\n    CryptoCode["USDB"] = "USDB";\n',
)

const usdbCoin = `    {
        cryptoCode: CryptoCode.USDB,
        display: 'USDB',
        cryptoCodeDisplay: 'USDB',
        code: 'usdb',
        unitScale: 6,
        tokenIdentifier: '${usdbTokenIdentifier}',
        type: 'spark-token',
        zeroConf: false,
        hideFromInstall: true,
        units: {
            full: {
                displayScale: 6,
                displayCode: 'USDB'
            }
        },
        isCashinOnly: false
    },
`

replaceOnce(
  consts,
  '    {\n        cryptoCode: CryptoCode.XMR,\n',
  usdbCoin + '    {\n        cryptoCode: CryptoCode.XMR,\n',
)

fs.writeFileSync(
  path.join(coinsDir, 'plugins', 'usdb.js'),
  `"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
var USDB = /** @class */ (function () {
    function USDB() {
        this.lengthLimit = Number.MAX_SAFE_INTEGER;
    }
    USDB.prototype.parseUrl = function (_network, url) {
        var res = /^(spark:)?([a-z0-9]+)/i.exec(url);
        var address = res && res[2];
        if (!address || !this.validate(_network, address))
            throw new Error('Invalid address');
        return address;
    };
    USDB.prototype.buildUrl = function (address) {
        return address;
    };
    USDB.prototype.depositUrl = function (address) {
        return address;
    };
    USDB.prototype.validate = function (_network, address) {
        return typeof address === 'string' && /^spark1[ac-hj-np-z02-9]+$/i.test(address);
    };
    USDB.prototype.formatAddress = function (address) {
        return address;
    };
    USDB.prototype.getAddressType = function () {
        return 'Spark';
    };
    return USDB;
}());
exports.default = new USDB();
`,
)

replaceOnce(
  utils,
  'var ln_1 = __importDefault(require("./plugins/ln"));\n',
  'var ln_1 = __importDefault(require("./plugins/ln"));\nvar usdb_1 = __importDefault(require("./plugins/usdb"));\n',
)

replaceOnce(
  utils,
  'var PLUGINS = { BTC: btc_1.default, ETH: eth_1.default, ZEC: zec_1.default, LTC: ltc_1.default, DASH: dash_1.default, BCH: bch_1.default, XMR: xmr_1.default, TRX: trx_1.default, LN: ln_1.default };\n',
  'var PLUGINS = { BTC: btc_1.default, ETH: eth_1.default, ZEC: zec_1.default, LTC: ltc_1.default, DASH: dash_1.default, BCH: bch_1.default, XMR: xmr_1.default, TRX: trx_1.default, LN: ln_1.default, USDB: usdb_1.default };\n',
)
NODE

if [[ -f "$BRAIN_FILE" ]]; then
node - "$BRAIN_FILE" <<'NODE'
const fs = require('fs')

const brainFile = process.argv[2]
let text = fs.readFileSync(brainFile, 'utf8')

if (!text.includes('function normalizeDepositAddress')) {
  text = text.replace(
    'Brain.prototype.commitCashOutTx = function commitCashOutTx () {\n',
    `function normalizeDepositAddress (address) {
  if (!address || typeof address !== 'object') return address
  return address.toAddress || address.address || address.layer2Address || address.walletId
}

Brain.prototype.commitCashOutTx = function commitCashOutTx () {
`,
  )
}

text = text.replace(
  `      const amountStr = this.toCryptoUnits(tx.cryptoAtoms, tx.cryptoCode).toString()
      const depositUrl = coinUtils.depositUrl(tx.cryptoCode, tx.toAddress, amountStr)
      const layer2Url = coinUtils.depositUrl(tx.cryptoCode, tx.layer2Address, amountStr)
      const toAddress = coinUtils.formatAddress(tx.cryptoCode, tx.toAddress)
      const layer2Address = coinUtils.formatAddress(tx.cryptoCode, tx.layer2Address)
`,
  `      const amountStr = this.toCryptoUnits(tx.cryptoAtoms, tx.cryptoCode).toString()
      const rawToAddress = normalizeDepositAddress(tx.toAddress)
      const rawLayer2Address = normalizeDepositAddress(tx.layer2Address) || rawToAddress
      const depositUrl = coinUtils.depositUrl(tx.cryptoCode, rawToAddress, amountStr)
      const layer2Url = coinUtils.depositUrl(tx.cryptoCode, rawLayer2Address, amountStr)
      const toAddress = coinUtils.formatAddress(tx.cryptoCode, rawToAddress)
      const layer2Address = coinUtils.formatAddress(tx.cryptoCode, rawLayer2Address)
`,
)

fs.writeFileSync(brainFile, text)
NODE
fi

if [[ -f "$APP_FILE" ]]; then
node - "$APP_FILE" <<'NODE'
const fs = require('fs')

const appFile = process.argv[2]
let text = fs.readFileSync(appFile, 'utf8')

if (!text.includes('function normalizeDepositPayload')) {
  text = text.replace(
    'function setDepositAddress (depositInfo) {\n',
    `function normalizeDepositPayload (value) {
  if (!value) return value

  if (typeof value === 'string') {
    const trimmed = value.trim()
    if (trimmed[0] !== '{') return value

    try {
      value = JSON.parse(trimmed)
    } catch (err) {
      return value
    }
  }

  if (typeof value !== 'object') return value
  return value.toAddress || value.address || value.layer2Address || value.walletId
}

function setDepositAddress (depositInfo) {
`,
  )
}

const oldSetDepositAddress = `function setDepositAddress (depositInfo) {
  $('.deposit_state .loading').hide()
  $('.deposit_state .send-notice .crypto-address').html(formatAddress(depositInfo.toAddress))
  $('.deposit_state .send-notice').show()

  qrize(depositInfo.depositUrl, $('#qr-code-deposit'), CASH_OUT_QR_COLOR)
  qrize(depositInfo.toAddress, $('#qr-code-deposit-address'), CASH_OUT_QR_COLOR)
}
`

const newSetDepositAddress = `function setDepositAddress (depositInfo) {
  const toAddress = normalizeDepositPayload(depositInfo.toAddress)
  const depositUrl = normalizeDepositPayload(depositInfo.depositUrl) || toAddress

  $('.deposit_state .loading').hide()
  $('.deposit_state .send-notice .crypto-address').html(formatAddress(toAddress))
  $('.deposit_state .send-notice').show()

  qrize(depositUrl, $('#qr-code-deposit'), CASH_OUT_QR_COLOR)
  qrize(toAddress, $('#qr-code-deposit-address'), CASH_OUT_QR_COLOR)
}
`

if (text.includes(oldSetDepositAddress)) {
  text = text.replace(oldSetDepositAddress, newSetDepositAddress)
} else if (!text.includes('const toAddress = normalizeDepositPayload(depositInfo.toAddress)')) {
  throw new Error(`Patch anchor not found in ${appFile}: setDepositAddress`)
}

fs.writeFileSync(appFile, text)
NODE
fi

if [[ -f "$SCANNER_FILE" ]]; then
node - "$SCANNER_FILE" "$DEVICE_CONFIG" "$INSTALL_MOCK_SPARK_QR" <<'NODE'
const fs = require('fs')

const scannerFile = process.argv[2]
const deviceConfig = process.argv[3]
const installMockSparkQr = process.argv[4] === 'true'
const defaultSparkAddress = 'spark1pgss9wuqykl7v83kaqnm3kwyakxd3ukycng45zx69nw3xjk3ds236f4gwq0sad'

function patchScanner () {
  let text = fs.readFileSync(scannerFile, 'utf8')

  if (!text.includes('function getMockWalletAddress')) {
    text = text.replace(
      'function config (_configuration) {\n',
      `function getMockWalletAddress (walletAddresses, cryptoCode) {
  if (walletAddresses[cryptoCode]) return walletAddresses[cryptoCode]
  if (cryptoCode === 'USDB') return walletAddresses.SPARK
}

function config (_configuration) {
`,
    )
  }

  text = text.replace(
    '      const walletAddress = devToolsValues.walletAddresses[cryptoCode] || mockData.qrData[cryptoCode]\n',
    `      const walletAddress =
        getMockWalletAddress(devToolsValues.walletAddresses, cryptoCode) ||
        getMockWalletAddress(mockData.qrData, cryptoCode)
`,
  )

  fs.writeFileSync(scannerFile, text)
}

function patchDeviceConfig () {
  if (!installMockSparkQr || !fs.existsSync(deviceConfig)) return

  const config = JSON.parse(fs.readFileSync(deviceConfig, 'utf8'))
  config.brain = config.brain || {}
  config.brain.mockCryptoQR = config.brain.mockCryptoQR || {}
  if (!config.brain.mockCryptoQR.SPARK) {
    config.brain.mockCryptoQR.SPARK = defaultSparkAddress
  }
  fs.writeFileSync(deviceConfig, `${JSON.stringify(config, null, 2)}\n`)
}

patchScanner()
patchDeviceConfig()
NODE
fi

echo "USDB/spark1 parser installed in $MACHINE_DIR"
if [[ "$INSTALL_MOCK_SPARK_QR" == "true" ]]; then
  echo "Mock USDB scan alias installed as brain.mockCryptoQR.SPARK"
fi
echo "Restart the machine process after applying this patch."
