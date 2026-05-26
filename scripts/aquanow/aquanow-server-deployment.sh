#!/usr/bin/env bash
set -euo pipefail

SERVER_DIR="${SERVER_DIR:-/usr/lib/node_modules/lamassu-server}"
SCRIPT_SOURCE="${BASH_SOURCE[0]-}"
if [[ -n "$SCRIPT_SOURCE" && -f "$SCRIPT_SOURCE" ]]; then
  SRC_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
else
  SRC_DIR=""
fi
AQUANOW_PLUGIN_SRC=""
if [[ -n "$SRC_DIR" ]]; then
  AQUANOW_PLUGIN_SRC="$SRC_DIR/lib/plugins/exchange/aquanow.js"
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

BACKUP_DIR="/root/aquanow-v12-backup-$(date +%Y%m%d-%H%M%S)"
echo "Backing up patched files..."
mkdir -p "$BACKUP_DIR"
for file in \
  "lib/plugins/exchange/aquanow.js" \
  "lib/exchange.js" \
  "lib/plugins/common/ccxt.js" \
  "lib/new-admin/config/accounts.js"
do
  if [[ -f "$SERVER_DIR/$file" ]]; then
    mkdir -p "$BACKUP_DIR/$(dirname "$file")"
    cp -a "$SERVER_DIR/$file" "$BACKUP_DIR/$file"
  fi
done
if [[ -d "$SERVER_DIR/public/assets" ]]; then
  mkdir -p "$BACKUP_DIR/public/assets"
  cp -a "$SERVER_DIR"/public/assets/*.js "$BACKUP_DIR/public/assets/" 2>/dev/null || true
fi

echo "Installing Aquanow exchange plugin..."
mkdir -p "$SERVER_DIR/lib/plugins/exchange"
if [[ -n "$AQUANOW_PLUGIN_SRC" && -f "$AQUANOW_PLUGIN_SRC" ]]; then
  cp "$AQUANOW_PLUGIN_SRC" "$SERVER_DIR/lib/plugins/exchange/aquanow.js"
else
  cat > "$SERVER_DIR/lib/plugins/exchange/aquanow.js" <<'AQUANOW_PLUGIN'
const crypto = require('crypto')

const axios = require('axios')
const { COINS, utils: coinUtils } = require('@lamassu/coins')
const _ = require('lodash/fp')

const logger = require('../../logger')

const BASE_URLS = {
  prod: 'https://api.aquanow.io',
  test: 'https://api-staging.aquanow.io',
}
const MARKET_URLS = {
  prod: 'https://market.aquanow.io',
  test: 'https://market-staging.aquanow.io',
}
const MARKET_ORDER_PATH = '/trades/v2/market'
const AVAILABLE_SYMBOLS_PATH = '/availablesymbols'
const REQUEST_TIMEOUT = 3000

const { BTC, ETH, LTC, BCH, USDT, USDT_TRON, TRX, LN, USDC } = COINS

const CRYPTO = [BTC, ETH, LTC, BCH, USDT, USDT_TRON, TRX, LN, USDC]
const FIAT = ['CAD', 'USD']
const DEFAULT_FIAT_MARKET = 'CAD'
const REQUIRED_CONFIG_FIELDS = [
  'apiKey',
  'privateKey',
  'currencyMarket',
]

const AMOUNT_PRECISION = {
  BTC: 8,
  ETH: 8,
  LTC: 8,
  BCH: 8,
  USDT: 6,
  TRX: 6,
  USDC: 6,
}

const DEFAULT_MARKETS = {
  CAD: ['BTC', 'ETH', 'LTC', 'BCH', 'USDT', 'TRX', 'USDC'],
  USD: ['BTC', 'ETH', 'LTC', 'BCH', 'USDT', 'TRX', 'USDC'],
}

function normalizeBaseUrl(baseUrl) {
  return String(baseUrl).replace(/\/+$/, '')
}

function getEnvironment(account = {}) {
  return account.environment === 'test' ? 'test' : 'prod'
}

function getBaseUrl(account = {}) {
  return normalizeBaseUrl(account.baseUrl || BASE_URLS[getEnvironment(account)])
}

function getMarketUrl(environment = 'prod') {
  return normalizeBaseUrl(MARKET_URLS[environment] || MARKET_URLS.prod)
}

function getSignature(httpMethod, path, nonce, apiSecret) {
  const signatureContent = JSON.stringify({
    httpMethod,
    path,
    nonce,
  })

  return crypto
    .createHmac('sha384', apiSecret)
    .update(signatureContent)
    .digest('hex')
}

function buildHeaders(account, httpMethod, path) {
  const nonce = Date.now().toString()

  return {
    'Content-Type': 'application/json',
    Accept: 'application/json',
    'x-nonce': nonce,
    'x-api-key': account.apiKey,
    'x-signature': getSignature(
      httpMethod,
      path,
      nonce,
      account.privateKey,
    ),
  }
}

function sanitizeUsernameRef(tradeId) {
  return `lamassu${tradeId || Date.now()}`
    .replace(/[^a-zA-Z0-9]/g, '')
    .slice(0, 63)
}

function formatAmount(cryptoAtoms, cryptoCode) {
  const precision = _.defaultTo(8, AMOUNT_PRECISION[cryptoCode])
  return coinUtils.toUnit(cryptoAtoms, cryptoCode).toFixed(precision)
}

function buildTicker(account, cryptoCode) {
  const fiatCode = _.toUpper(account.currencyMarket)
  if (!_.includes(fiatCode, FIAT))
    throw new Error(`Unsupported Aquanow fiat market: ${fiatCode}`)

  if (!_.includes(cryptoCode, DEFAULT_MARKETS[fiatCode] || []))
    throw new Error(`Unsupported Aquanow crypto market: ${cryptoCode}`)

  return `${cryptoCode}-${fiatCode}`
}

function isConfigValid(account) {
  return _.every(field => {
    const value = account && account[field]
    return value || value === 0
  }, REQUIRED_CONFIG_FIELDS)
}

function extractErrorMessage(data) {
  const errors = data && data.errors
  if (Array.isArray(errors) && errors.length > 0)
    return errors
      .map(error => error && error.message)
      .filter(Boolean)
      .join('; ')

  if (data && data.data) return extractErrorMessage(data.data)

  return data && (data.message || data.error)
}

function isRejectedOrder(data) {
  const status = data && String(data.status || data.orderStatus || '').toLowerCase()
  return ['error', 'rejected', 'failed', 'cancelled', 'canceled'].includes(status)
}

function normalizeResponse(response) {
  const body = response.data
  const data = body && body.data ? body.data : body
  const errorMessage = extractErrorMessage(body)

  if (errorMessage) {
    const error = new Error(errorMessage)
    if (/minimum|smaller than|required minimum|trade size/i.test(errorMessage))
      error.name = 'orderTooSmall'
    throw error
  }

  if (!data) throw new Error('Aquanow returned an empty response')
  if (isRejectedOrder(data)) {
    throw new Error(data.message || data.error || 'Aquanow market order failed')
  }

  const receiveQuantity = Number(data.receiveQuantity || 0)
  const deliverQuantity = Number(data.deliverQuantity || 0)
  if (receiveQuantity === 0 && deliverQuantity === 0)
    throw new Error('Aquanow market order was not filled')

  return body
}

function trade(side, account, tradeEntry) {
  if (!isConfigValid(account)) throw new Error('Invalid config')

  const { cryptoAtoms, cryptoCode: _cryptoCode, tradeId } = tradeEntry
  const cryptoCode = coinUtils.getEquivalentCode(_cryptoCode)
  const amount = formatAmount(cryptoAtoms, cryptoCode)
  const ticker = buildTicker(account, cryptoCode)
  const body = {
    ticker,
    tradeSide: side,
    usernameRef: sanitizeUsernameRef(tradeId),
  }

  if (side === 'buy') body.receiveQuantity = amount
  else body.deliverQuantity = amount

  const url = `${getBaseUrl(account)}${MARKET_ORDER_PATH}`
  const headers = buildHeaders(account, 'POST', MARKET_ORDER_PATH)

  return axios
    .post(url, body, { headers, timeout: REQUEST_TIMEOUT })
    .then(normalizeResponse)
    .catch(err => {
      const errorMessage = extractErrorMessage(_.get('response.data', err))
      if (errorMessage) {
        const error = new Error(errorMessage)
        if (/minimum|smaller than|required minimum|trade size/i.test(errorMessage))
          error.name = 'orderTooSmall'
        throw error
      }

      throw err
    })
}

function extractSymbol(value) {
  if (typeof value === 'string') return value
  return value && (value.symbol || value.ticker || value.pair)
}

function parseSymbols(symbols, availableCryptos) {
  const prunedCryptos = _.compose(
    _.uniq,
    _.map(coinUtils.getEquivalentCode),
  )(availableCryptos)

  return _.reduce(
    (acc, value) => {
      const symbol = extractSymbol(value)
      if (!symbol) return acc

      const [base, quote] = symbol.split('-')
      if (!_.includes(quote, FIAT)) return acc
      if (!_.includes(base, prunedCryptos)) return acc

      return {
        ...acc,
        [quote]: _.uniq([...(acc[quote] || []), base]),
      }
    },
    {},
    symbols,
  )
}

function normalizeMarkets(data, availableCryptos) {
  const symbols = Array.isArray(data)
    ? data
    : data && (data.data || data.symbols || data.availableSymbols || [])

  const markets = parseSymbols(symbols, availableCryptos)
  return _.isEmpty(markets) ? DEFAULT_MARKETS : markets
}

function getMarkets(availableCryptos) {
  return Promise.all([
    axios
      .get(`${getMarketUrl('prod')}${AVAILABLE_SYMBOLS_PATH}`, {
        timeout: REQUEST_TIMEOUT,
      })
      .then(response => normalizeMarkets(response.data, availableCryptos))
      .catch(error => {
        logger.error('Error fetching Aquanow production markets:', error.message)
        return DEFAULT_MARKETS
      }),
  ]).then(([prodMarkets]) =>
    _.flatMap(fiat =>
      _.map(
        cryptoCode => ({
          cryptoCode,
          fiatCode: fiat,
        }),
        prodMarkets[fiat] || [],
      ),
    )(FIAT),
  )
}

module.exports = {
  CRYPTO,
  FIAT,
  DEFAULT_FIAT_MARKET,
  trade,
  getMarkets,
}
AQUANOW_PLUGIN
fi

echo "Patching Lamassu server files..."
node - "$SERVER_DIR" <<'NODE'
const fs = require('fs')
const path = require('path')

const serverDir = process.argv[2]

function read(file) {
  return fs.readFileSync(file, 'utf8')
}

function write(file, text) {
  fs.writeFileSync(file, text)
}

function replaceOnce(file, search, replacement) {
  let text = read(file)
  if (text.includes(replacement)) return
  if (!text.includes(search)) {
    throw new Error(`Patch anchor not found in ${file}: ${search.slice(0, 120)}`)
  }
  text = text.replace(search, replacement)
  write(file, text)
}

const exchange = path.join(serverDir, 'lib', 'exchange.js')
const ccxt = path.join(serverDir, 'lib', 'plugins', 'common', 'ccxt.js')
const accounts = path.join(serverDir, 'lib', 'new-admin', 'config', 'accounts.js')

replaceOnce(
  ccxt,
  "const bitfinex = require('../exchange/bitfinex')\n",
  "const bitfinex = require('../exchange/bitfinex')\nconst aquanow = require('../exchange/aquanow')\n",
)
replaceOnce(
  ccxt,
  'const ALL = {\n',
  'const ALL = {\n  aquanow: aquanow,\n',
)

let exchangeText = read(exchange)
if (!exchangeText.includes("require('./plugins/exchange/aquanow')")) {
  exchangeText = exchangeText.replace(
    "const mockExchange = require('./plugins/exchange/mock-exchange')\n",
    "const mockExchange = require('./plugins/exchange/mock-exchange')\nconst aquanow = require('./plugins/exchange/aquanow')\n",
  )
}
if (!exchangeText.includes('const customExchanges = {')) {
  exchangeText = exchangeText.replace(
    "const accounts = require('./new-admin/config/accounts')\n",
    "const accounts = require('./new-admin/config/accounts')\n\nconst customExchanges = {\n  aquanow,\n}\n",
  )
}
if (!exchangeText.includes("customExchanges[r.exchangeName].trade('buy'")) {
  exchangeText = exchangeText.replace(
    "    return ccxt.trade('buy', r.account, tradeEntry, r.exchangeName)\n",
    "    if (customExchanges[r.exchangeName])\n      return customExchanges[r.exchangeName].trade('buy', r.account, tradeEntry)\n\n    return ccxt.trade('buy', r.account, tradeEntry, r.exchangeName)\n",
  )
}
if (!exchangeText.includes("customExchanges[r.exchangeName].trade('sell'")) {
  exchangeText = exchangeText.replace(
    "    return ccxt.trade('sell', r.account, tradeEntry, r.exchangeName)\n",
    "    if (customExchanges[r.exchangeName])\n      return customExchanges[r.exchangeName].trade('sell', r.account, tradeEntry)\n\n    return ccxt.trade('sell', r.account, tradeEntry, r.exchangeName)\n",
  )
}
if (!exchangeText.includes('const markets = customExchanges[exchange]')) {
  const cleanBlock = `  const fetchMarketForExchange = exchange =>
    ccxt
      .getMarkets(exchange, ALL_CRYPTOS)
      .then(markets => ({ exchange, markets }))
      .catch(error => {
        logger.error(\`Error fetching markets for \${exchange}:\`, error)
        return {
          exchange,
          markets: [],
          error: error.message,
        }
      })
`
  const patchedBlock = `  const fetchMarketForExchange = exchange => {
    const markets = customExchanges[exchange]
      ? customExchanges[exchange].getMarkets(ALL_CRYPTOS)
      : ccxt.getMarkets(exchange, ALL_CRYPTOS)

    return markets
      .then(markets => ({ exchange, markets }))
      .catch(error => {
        logger.error(\`Error fetching markets for \${exchange}:\`, error)
        return {
          exchange,
          markets: [],
          error: error.message,
        }
      })
  }
`
  if (!exchangeText.includes(cleanBlock)) throw new Error(`Patch anchor not found in ${exchange}: fetchMarketForExchange`)
  exchangeText = exchangeText.replace(cleanBlock, patchedBlock)
}
write(exchange, exchangeText)

let accountsText = read(accounts)
if (!accountsText.includes(' aquanow,') && !accountsText.includes('const { aquanow,')) {
  accountsText = accountsText.replace(
    'const { bitpay, itbit, bitstamp, kraken, binanceus, cex, binance, bitfinex } =\n  ALL',
    'const {\n  aquanow,\n  bitpay,\n  itbit,\n  bitstamp,\n  kraken,\n  binanceus,\n  cex,\n  binance,\n  bitfinex,\n} = ALL',
  )
}
if (!accountsText.includes("code: 'aquanow'")) {
  accountsText = accountsText.replace(
    "  {\n    code: 'binance',\n",
    "  {\n    code: 'aquanow',\n    display: 'Aquanow',\n    class: EXCHANGE,\n    cryptos: aquanow.CRYPTO,\n  },\n  {\n    code: 'binance',\n",
  )
}
write(accounts, accountsText)

const publicAssets = path.join(serverDir, 'public', 'assets')
if (fs.existsSync(publicAssets)) {
  for (const name of fs.readdirSync(publicAssets)) {
    if (!name.endsWith('.js')) continue

    const file = path.join(publicAssets, name)
    let text = read(file)
    if (!text.includes('getMarkets')) continue
    if (text.includes('Aquanow (Exchange)')) continue
    if (!text.includes(',Dp=(e={})=>{const ')) continue

    const schema = ',Aqn=e=>({code:"aquanow",name:"Aquanow",title:"Aquanow (Exchange)",elements:[{code:"apiKey",display:"API key",component:ht,face:!0,long:!0},{code:"privateKey",display:"API secret",component:hr},{code:"environment",display:"Environment",component:On,inputProps:{options:[{code:"prod",display:"prod"},{code:"test",display:"test"}],labelProp:"display",valueProp:"code"},face:!0},{code:"currencyMarket",display:"Currency market",component:On,inputProps:{options:jp(e),labelProp:"display",valueProp:"code"},face:!0}],getValidationSchema:t=>dt().shape({apiKey:Me().max(200,"The API key is too long").required("The API key is required"),privateKey:Me().max(200,"The API secret is too long").test(ui(t==null?void 0:t.privateKey,"API secret")),environment:Me().matches(/(prod|test)/).required("The environment is required"),currencyMarket:Me().required("The currency market is required")})})'
    text = text.replace(',Dp=(e={})=>{const ', `${schema},Dp=(e={})=>{const aq=Aqn(e==null?void 0:e.aquanow),`)

    const dpIndex = text.indexOf(',Dp=(e={})=>{const aq=')
    const returnIndex = text.indexOf('return{[', dpIndex)
    if (dpIndex === -1 || returnIndex === -1) {
      throw new Error(`Could not patch Aquanow admin schema into ${file}`)
    }
    text =
      text.slice(0, returnIndex) +
      'return{[aq.code]:aq,' +
      text.slice(returnIndex + 'return{'.length)

    write(file, text)
  }
}
NODE

echo "Validating Aquanow patch..."
node --check "$SERVER_DIR/lib/plugins/exchange/aquanow.js"
node --check "$SERVER_DIR/lib/exchange.js"
node --check "$SERVER_DIR/lib/plugins/common/ccxt.js"
node --check "$SERVER_DIR/lib/new-admin/config/accounts.js"
node - "$SERVER_DIR" <<'NODE'
const path = require('path')
const serverDir = process.argv[2]
const aquanow = require(path.join(serverDir, 'lib', 'plugins', 'exchange', 'aquanow'))
const accounts = require(path.join(serverDir, 'lib', 'new-admin', 'config', 'accounts'))

if (!aquanow.CRYPTO || !aquanow.FIAT) throw new Error('Aquanow adapter did not load')
if (!accounts.ACCOUNT_LIST.some(account => account.code === 'aquanow' && account.class === 'exchange')) {
  throw new Error('Aquanow account was not registered')
}
console.log('Aquanow adapter and account registry loaded.')
NODE

if [[ "${SKIP_RESTART:-0}" == "1" ]]; then
  echo "SKIP_RESTART=1 set; leaving Lamassu services running."
else
  echo "Restarting Lamassu services..."
  supervisorctl restart lamassu-server lamassu-admin-server
fi

echo "Aquanow v12 exchange patch installed."
