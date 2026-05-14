#!/usr/bin/env bash
set -euo pipefail

SERVER_DIR="${SERVER_DIR:-/usr/lib/node_modules/lamassu-server}"
SDK_DIR="$SERVER_DIR/spark-sdk-install"
SCRIPT_SOURCE="${BASH_SOURCE[0]-}"
if [[ -n "$SCRIPT_SOURCE" && -f "$SCRIPT_SOURCE" ]]; then
  SRC_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
else
  SRC_DIR=""
fi
USDB_TOKEN_IDENTIFIER="${SPARK_USDB_TOKEN_IDENTIFIER:-btkn1xgrvjwey5ngcagvap2dzzvsy4uk8ua9x69k82dwvt5e7ef9drm9qztux87}"
RAW_BASE="${SPARK_PATCH_RAW_BASE:-https://raw.githubusercontent.com/Lamatos/lamassu-patches/master/scripts/spark}"
SPARK_PLUGIN_SRC=""
if [[ -n "$SRC_DIR" ]]; then
  SPARK_PLUGIN_SRC="$SRC_DIR/lib/plugins/wallet/spark/spark.js"
fi
TMP_DIR=""

cleanup () {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

if [[ "$(id -u)" != "0" ]]; then
  echo "Please run as root."
  exit 1
fi

if [[ ! -d "$SERVER_DIR" ]]; then
  echo "Lamassu server not found at $SERVER_DIR"
  exit 1
fi

echo "Installing Spark SDK dependencies..."
mkdir -p "$SDK_DIR"
npm install --prefix "$SDK_DIR" @buildonspark/spark-sdk@0.7.15 @lamassu/bolt11@1.5.1

echo "Installing Spark wallet plugin..."
mkdir -p "$SERVER_DIR/lib/plugins/wallet/spark"
if [[ -z "$SPARK_PLUGIN_SRC" || ! -f "$SPARK_PLUGIN_SRC" ]]; then
  TMP_DIR="$(mktemp -d)"
  SPARK_PLUGIN_SRC="$TMP_DIR/spark.js"
  curl -fsSL "$RAW_BASE/spark.js" -o "$SPARK_PLUGIN_SRC"
fi
cp "$SPARK_PLUGIN_SRC" "$SERVER_DIR/lib/plugins/wallet/spark/spark.js"

echo "Patching Lamassu server files..."
node - "$SERVER_DIR" "$USDB_TOKEN_IDENTIFIER" <<'NODE'
const fs = require('fs')
const path = require('path')

const serverDir = process.argv[2]
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

function writeFile(file, content) {
  fs.mkdirSync(path.dirname(file), { recursive: true })
  fs.writeFileSync(file, content)
}

const coinsRoot = path.join(serverDir, 'node_modules', '@lamassu', 'coins', 'dist')
const consts = path.join(coinsRoot, 'config', 'consts.js')
const utils = path.join(coinsRoot, 'utils.js')
const lightUtils = path.join(coinsRoot, 'lightUtils.js')
const ticker = path.join(serverDir, 'lib', 'ticker.js')
const accounts = path.join(serverDir, 'lib', 'new-admin', 'config', 'accounts.js')
const wallet = path.join(serverDir, 'lib', 'wallet.js')
const sendCoinsBin = path.join(serverDir, 'bin', 'lamassu-send-coins')

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

writeFile(
  path.join(coinsRoot, 'plugins', 'usdb.js'),
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

replaceOnce(
  lightUtils,
  '        case \'LN\':\n            return \'BTC\';\n',
  '        case \'LN\':\n            return \'BTC\';\n        case \'USDB\':\n            return \'USD\';\n',
)

let tickerText = fs.readFileSync(ticker, 'utf8')
tickerText = tickerText.replace(
  "const sparkUsdb = require('./plugins/ticker/spark-usdb/spark-usdb')\n",
  '',
)

if (!tickerText.includes("const BN = require('./bn')")) {
  tickerText = tickerText.replace(
    "const mem = require('mem')\n",
    "const mem = require('mem')\nconst BN = require('./bn')\n",
  )
}

if (!tickerText.includes("const { getRate } = require('./forex')")) {
  tickerText = tickerText.replace(
    "const logger = require('./logger')\n",
    "const logger = require('./logger')\nconst { getRate } = require('./forex')\n",
  )
}

if (!tickerText.includes('function sparkUsdbTicker')) {
  tickerText = tickerText.replace(
    'function buildTicker',
    `function sparkUsdbTicker (fiatCode, cryptoCode) {
  if (cryptoCode !== 'USDB' && cryptoCode !== 'USD') {
    return Promise.reject(new Error(\`Unsupported crypto: \${cryptoCode}\`))
  }

  if (fiatCode === 'USD') {
    return Promise.resolve({ rates: { ask: BN(1), bid: BN(1) } })
  }

  return getRate(1, fiatCode, 'USD').then(({ fxRate }) => ({
    rates: { ask: fxRate, bid: fxRate },
  }))
}

function buildTicker`,
  )
}

if (!tickerText.includes("tickerName === 'spark-usdb'")) {
  if (tickerText.includes("  if (tickerName === 'bitpay') return bitpay.ticker(fiatCode, cryptoCode)\n")) {
    tickerText = tickerText.replace(
      "  if (tickerName === 'bitpay') return bitpay.ticker(fiatCode, cryptoCode)\n",
      "  if (tickerName === 'spark-usdb') return sparkUsdbTicker(fiatCode, cryptoCode)\n  if (tickerName === 'bitpay') return bitpay.ticker(fiatCode, cryptoCode)\n",
    )
    fs.writeFileSync(ticker, tickerText)
  } else if (tickerText.includes("          : ccxt\n")) {
    tickerText = tickerText.replace(
      "          : ccxt\n",
      "          : tickerName === 'spark-usdb'\n            ? { ticker: sparkUsdbTicker }\n            : ccxt\n",
    )
    fs.writeFileSync(ticker, tickerText)
  } else {
    throw new Error(`No ticker build anchor found in ${ticker}`)
  }
}
tickerText = tickerText.replace(
  'return sparkUsdb.ticker(fiatCode, cryptoCode)',
  'return sparkUsdbTicker(fiatCode, cryptoCode)',
)
fs.writeFileSync(ticker, tickerText)

let walletText = fs.readFileSync(wallet, 'utf8')
if (!walletText.includes('function fetchWalletByPlugin')) {
  walletText = walletText.replace(
    'function fetchWallet(settings, cryptoCode) {\n  return fs.readFile(MNEMONIC_PATH, \'utf8\').then(mnemonic => {\n    const masterSeed = mnemonicHelpers.toEntropyBuffer(mnemonic)\n    const plugin = configManager.getWalletSettings(\n      cryptoCode,\n      settings.config,\n    ).wallet\n',
    'function fetchWalletByPlugin(settings, plugin) {\n  return fs.readFile(MNEMONIC_PATH, \'utf8\').then(mnemonic => {\n    const masterSeed = mnemonicHelpers.toEntropyBuffer(mnemonic)\n',
  )
  walletText = walletText.replace(
    '}\n\nconst lastBalance = {}\n',
    '}\n\nfunction fetchWallet(settings, cryptoCode) {\n  const plugin = configManager.getWalletSettings(\n    cryptoCode,\n    settings.config,\n  ).wallet\n  return fetchWalletByPlugin(settings, plugin)\n}\n\nconst lastBalance = {}\n',
  )
}
if (!walletText.includes('function normalizeWalletAddressResult')) {
  walletText = walletText.replace(
    'function newAddress(settings, info, tx) {\n',
    `function normalizeWalletAddressResult(walletAddress, layer2Address) {
  if (!walletAddress || typeof walletAddress !== 'object') {
    return { toAddress: walletAddress, layer2Address }
  }

  return {
    toAddress: walletAddress.toAddress || walletAddress.address,
    layer2Address:
      walletAddress.layer2Address || walletAddress.walletId || layer2Address,
  }
}

function newAddress(settings, info, tx) {
`,
  )
}

walletText = walletText.replace(
  `  return Promise.all([
    walletAddressPromise,
    layer2.newAddress(settings, info),
  ]).then(([toAddress, layer2Address]) => ({
    toAddress,
    layer2Address,
  }))
`,
  `  return Promise.all([
    walletAddressPromise,
    layer2.newAddress(settings, info),
  ]).then(([toAddress, layer2Address]) =>
    normalizeWalletAddressResult(toAddress, layer2Address),
  )
`,
)
if (!walletText.includes('function sendCoinsWithWallet')) {
  walletText = walletText.replace(
    'function sendCoinsBatch(settings, txs, cryptoCode) {\n',
    `function sendCoinsWithWallet(settings, walletPlugin, tx) {
  return fetchWalletByPlugin(settings, walletPlugin)
    .then(r => {
      const feeMultiplier = new BN(
        configManager.getWalletSettings(
          tx.cryptoCode,
          settings.config,
        ).feeMultiplier,
      )
      return r.wallet
        .sendCoins(r.account, tx, settings, feeMultiplier)
        .then(res => {
          mem.clear(module.exports.balance)
          return res
        })
    })
    .catch(err => {
      if (err.name === INSUFFICIENT_FUNDS_NAME) {
        throw httpError(INSUFFICIENT_FUNDS_NAME, INSUFFICIENT_FUNDS_CODE)
      }
      throw err
    })
}

function sendCoinsBatch(settings, txs, cryptoCode) {
`,
  )
}

if (!walletText.includes('sendCoinsWithWallet,')) {
  walletText = walletText.replace(
    '  sendCoins,\n',
    '  sendCoins,\n  sendCoinsWithWallet,\n',
  )
}
fs.writeFileSync(wallet, walletText)

let sendCoinsText = fs.readFileSync(sendCoinsBin, 'utf8')
if (!sendCoinsText.includes('function isSparkAddress')) {
  sendCoinsText = sendCoinsText.replace(
    'const [toAddress, cryptoValue, cryptoCode] = process.argv.slice(2)\n',
    `const [toAddress, cryptoValue, cryptoCode] = process.argv.slice(2)

function isSparkAddress (address) {
  if (typeof address !== 'string') return false
  const lower = address.toLowerCase()
  return (
    lower.startsWith('spark1') ||
    lower.startsWith('sparkrt1') ||
    lower.startsWith('sprt1')
  )
}
`,
  )
}

if (!sendCoinsText.includes('const useSparkWallet = cryptoCode')) {
  sendCoinsText = sendCoinsText.replace(
    '    const fiatCode = configManager.getGlobalLocale(settings.config).fiatCurrency\n\n    return wallet.isStrictAddress(settings, cryptoCode, toAddress)\n',
    '    const fiatCode = configManager.getGlobalLocale(settings.config).fiatCurrency\n    const useSparkWallet = cryptoCode === \'BTC\' && isSparkAddress(toAddress)\n\n    return (useSparkWallet\n      ? Promise.resolve(true)\n      : wallet.isStrictAddress(settings, cryptoCode, toAddress))\n',
  )
}

if (!sendCoinsText.includes("wallet.sendCoinsWithWallet(settings, 'spark', tx)")) {
  sendCoinsText = sendCoinsText.replace(
    '            console.log(\'Sending...\')\n            return wallet.sendCoins(settings, { toAddress, cryptoAtoms, cryptoCode })\n',
    `            console.log('Sending...')
            const tx = { toAddress, cryptoAtoms, cryptoCode }
            const sendPromise = useSparkWallet
              ? wallet.sendCoinsWithWallet(settings, 'spark', tx)
              : wallet.sendCoins(settings, tx)

            return sendPromise
`,
  )
}

fs.writeFileSync(sendCoinsBin, sendCoinsText)

let accountsText = fs.readFileSync(accounts, 'utf8')
if (!accountsText.includes('USDB')) {
  accountsText = accountsText.replace(
    'const { BTC, BCH, DASH, ETH, LTC, USDT, ZEC, XMR, LN, TRX, USDT_TRON, USDC } =\n  COINS',
    'const { BTC, BCH, DASH, ETH, LTC, USDT, ZEC, XMR, LN, TRX, USDT_TRON, USDC, USDB } =\n  COINS',
  )
}

if (!accountsText.includes("code: 'spark-usdb'")) {
  if (accountsText.includes("  {\n    code: 'custom-ticker',\n")) {
    accountsText = accountsText.replace(
      "  {\n    code: 'custom-ticker',\n",
      "  {\n    code: 'spark-usdb',\n    display: 'Spark USDB',\n    class: TICKER,\n    cryptos: [USDB],\n  },\n  {\n    code: 'custom-ticker',\n",
    )
  } else {
    accountsText = accountsText.replace(
      "  { code: 'itbit', display: 'itBit', class: TICKER, cryptos: itbit.CRYPTO },\n",
      "  { code: 'itbit', display: 'itBit', class: TICKER, cryptos: itbit.CRYPTO },\n  { code: 'spark-usdb', display: 'Spark USDB', class: TICKER, cryptos: [USDB] },\n",
    )
  }
}

if (!accountsText.includes("code: 'spark', display: 'Spark'")) {
  accountsText = accountsText.replace(
    "  { code: 'galoy', display: 'Galoy', class: WALLET, cryptos: [LN] },\n",
    "  { code: 'galoy', display: 'Galoy', class: WALLET, cryptos: [LN] },\n  { code: 'spark', display: 'Spark', class: WALLET, cryptos: [LN, USDB] },\n",
  )
} else {
  accountsText = accountsText.replace(
    "{ code: 'spark', display: 'Spark', class: WALLET, cryptos: [USDB] }",
    "{ code: 'spark', display: 'Spark', class: WALLET, cryptos: [LN, USDB] }",
  )
}

fs.writeFileSync(accounts, accountsText)

const publicAssets = path.join(serverDir, 'public', 'assets')
if (fs.existsSync(publicAssets)) {
  for (const name of fs.readdirSync(publicAssets)) {
    if (!name.endsWith('.js')) continue

    const file = path.join(publicAssets, name)
    let text = fs.readFileSync(file, 'utf8')
    if (!text.includes('Unsupported crypto:')) continue

    text = text.replace(
      'r.USDT_TRON="USDT_TRON",r.LN="LN"',
      'r.USDT_TRON="USDT_TRON",r.LN="LN",r.USDB="USDB"',
    )

    const lnCoin =
      '{cryptoCode:t.LN,display:"Lightning Network",code:"ln",configFile:null,daemon:null,defaultPort:null,unitScale:8,zeroConf:!0,hideFromInstall:!0,type:"coin",units:{full:{displayScale:8,displayCode:"BTC"},mili:{displayScale:5,displayCode:"mBTC"}}}'
    const usdbCoin =
      '{cryptoCode:t.USDB,display:"USDB",displayCode:"USDB",code:"usdb",unitScale:6,tokenIdentifier:"' +
      usdbTokenIdentifier +
      '",type:"spark-token",zeroConf:!1,hideFromInstall:!0,units:{full:{displayScale:6,displayCode:"USDB"}},isCashinOnly:!1}'

    if (text.includes(lnCoin) && !text.includes('cryptoCode:t.USDB')) {
      text = text.replace(lnCoin + '];', lnCoin + ',' + usdbCoin + '];')
    }

    text = text.replace(
      'case"LN":return"BTC";default:return a',
      'case"LN":return"BTC";case"USDB":return"USD";default:return a',
    )

    fs.writeFileSync(file, text)
  }
}
NODE

echo "Seeding USDB wallet defaults..."
node - "$SERVER_DIR" <<'NODE'
const fs = require('fs')
const path = require('path')
const serverDir = process.argv[2]

const envFile = '/etc/lamassu/.env'
if (fs.existsSync(envFile)) {
  const lines = fs.readFileSync(envFile, 'utf8').split(/\r?\n/)
  for (const line of lines) {
    const trimmed = line.trim()
    if (!trimmed || trimmed.startsWith('#')) continue

    const match = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(trimmed)
    if (!match) continue

    let value = match[2].trim()
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1)
    }

    process.env[match[1]] = value
  }
}

const settingsLoader = require(path.join(serverDir, 'lib', 'new-settings-loader'))

const config = {
  wallets_LN_wallet: 'spark',
  wallets_USDB_zeroConfLimit: 0,
  wallets_USDB_coin: 'USDB',
  wallets_USDB_zeroConf: 'none',
  wallets_USDB_wallet: 'spark',
  wallets_USDB_ticker: 'spark-usdb',
  wallets_USDB_exchange: 'no-exchange',
}

settingsLoader.saveConfig(config).then(() => {
  console.log('USDB wallet defaults saved.')
}).catch(err => {
  console.error(err)
  process.exit(1)
})
NODE

echo "Restarting Lamassu services..."
supervisorctl restart lamassu-server lamassu-admin-server

echo "Full Spark/USDB server patch installed."
