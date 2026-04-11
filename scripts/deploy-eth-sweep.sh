#!/bin/bash
# =============================================================================
# deploy-eth-sweep.sh
#
# Installs the Lamassu ETH cash-out sweep tool onto the server.
# Run as root on the Lamassu server:
#
#   curl -sS https://raw.githubusercontent.com/Lamatos/lamassu-patches/refs/heads/master/scripts/eth-cashout-sweep/deploy-eth-sweep.sh | bash
#
# After install, run anytime with:
#   sudo lamassu-eth-sweep
# =============================================================================
set -e

INSTALL_DIR="/opt/lamassu-tools"
SCRIPT_PATH="$INSTALL_DIR/eth-cashout-sweep.js"
BIN_PATH="/usr/local/bin/lamassu-eth-sweep"
SERVER_ROOT="/usr/lib/node_modules/lamassu-server"

# ---- Guards -----------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: Please run as root (sudo)."
  exit 1
fi

if [ ! -d "$SERVER_ROOT" ]; then
  echo "ERROR: lamassu-server not found at $SERVER_ROOT"
  echo "Is this a Lamassu server?"
  exit 1
fi

if [ ! -f "$SERVER_ROOT/.env" ]; then
  echo "ERROR: No .env found at $SERVER_ROOT/.env"
  echo "Server environment is not set up correctly."
  exit 1
fi

# ---- Install ----------------------------------------------------------------
echo "Installing Lamassu ETH cash-out sweep tool..."
mkdir -p "$INSTALL_DIR"

# Write the Node.js sweep script
cat > "$SCRIPT_PATH" << 'NODEJS_SCRIPT'
#!/usr/bin/env node
/**
 * eth-cashout-sweep.js
 *
 * Queries the DB for all ETH cash-out payment addresses, checks their on-chain
 * balances, shows the operator which ones have sweepable funds, and sweeps them
 * to the hot wallet after confirmation.
 *
 * Cash-out flow reminder:
 *   Customer wants cash → machine generates HD payment address → customer sends ETH there
 *   → machine dispenses cash → server should sweep ETH back to hot wallet (may have failed)
 */

'use strict'

require('./lib/environment-helper')

const fs = require('fs')
const readline = require('readline')
const hdkey = require('ethereumjs-wallet/hdkey')
const hkdf = require('futoin-hkdf')
const { FeeMarketEIP1559Transaction } = require('@ethereumjs/tx')
const { default: Common, Chain, Hardfork } = require('@ethereumjs/common')
const Web3 = require('web3')
const _ = require('lodash/fp')

const db = require('./lib/db')
const mnemonicHelpers = require('./lib/mnemonic-helpers')
const settingsLoader = require('./lib/new-settings-loader')
const configManager = require('./lib/new-config-manager')
const BN = require('./lib/bn')

// ---- Constants --------------------------------------------------------------
const PAYMENT_PREFIX_PATH = "m/44'/60'/0'/0'"
const DEFAULT_PREFIX_PATH  = "m/44'/60'/1'/0'"
const ETH_TRANSFER_GAS     = 21000  // fixed for a plain ETH send
const CHAIN_ID             = 1

// Skip addresses where even after gas there's less than this. 0.001 ETH.
const DUST_THRESHOLD_WEI = BN('1000000000000000')

const MNEMONIC_PATH = process.env.MNEMONIC_PATH
const web3 = new Web3()
let lastUsedNonces = {}

// ---- Utilities --------------------------------------------------------------
const delay = ms => new Promise(r => setTimeout(r, ms))
const hex   = bn => '0x' + bn.integerValue(BN.ROUND_DOWN).toString(16)

function prompt(question) {
  return new Promise(resolve => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout })
    rl.question(question, ans => { rl.close(); resolve(ans.trim().toLowerCase()) })
  })
}

function computeSeed(mnemonic) {
  const masterSeed = mnemonicHelpers.toEntropyBuffer(mnemonic.trim())
  return hkdf(masterSeed, 32, { salt: 'lamassu-server-salt', info: 'wallet-seed' })
}

function paymentWallet(seed, hdIndex) {
  return hdkey.fromMasterSeed(seed)
    .derivePath(PAYMENT_PREFIX_PATH)
    .deriveChild(parseInt(hdIndex, 10))
    .getWallet()
}

function hotWallet(seed) {
  return hdkey.fromMasterSeed(seed)
    .derivePath(DEFAULT_PREFIX_PATH)
    .deriveChild(0)
    .getWallet()
}

async function getEthBalance(address) {
  const raw = await web3.eth.getBalance(address.toLowerCase())
  return BN(raw || 0)
}

async function getCurrentFees() {
  const block = await web3.eth.getBlock('pending')
  const baseFeePerGas        = BN(block.baseFeePerGas)
  const maxPriorityFeePerGas = BN(web3.utils.toWei('1.5', 'gwei'))
  const maxFeePerGas         = baseFeePerGas.times(2).plus(maxPriorityFeePerGas)
  return { baseFeePerGas, maxPriorityFeePerGas, maxFeePerGas }
}

async function buildSweepTx(fromWallet, toAddress, balance, fees) {
  const fromAddress = '0x' + fromWallet.getAddress().toString('hex')
  const common      = new Common({ chain: Chain.Mainnet, hardfork: Hardfork.London })

  const txCount = await web3.eth.getTransactionCount(fromAddress)
  const nonce   = _.max([0, txCount, (lastUsedNonces[fromAddress] || -1) + 1])
  lastUsedNonces[fromAddress] = nonce

  const gas    = BN(ETH_TRANSFER_GAS)
  const fee    = fees.maxFeePerGas.times(gas)
  const toSend = balance.minus(fee)

  if (toSend.lte(0)) {
    throw new Error(`Balance (${balance.toFixed(0)} wei) cannot cover gas (${fee.toFixed(0)} wei)`)
  }

  const rawTx = {
    chainId: CHAIN_ID,
    nonce,
    maxPriorityFeePerGas: hex(fees.maxPriorityFeePerGas),
    maxFeePerGas: hex(fees.maxFeePerGas),
    gasLimit: hex(gas),
    to: toAddress.toLowerCase(),
    value: hex(toSend),
  }

  const tx     = FeeMarketEIP1559Transaction.fromTxData(rawTx, { common })
  const signed = tx.sign(fromWallet.getPrivateKey())
  return '0x' + signed.serialize().toString('hex')
}

function sendRaw(rawTx) {
  return new Promise((resolve, reject) => {
    web3.eth.sendSignedTransaction(rawTx)
      .on('transactionHash', resolve)
      .on('error', reject)
  })
}

// ---- Main -------------------------------------------------------------------
async function main() {
  if (!MNEMONIC_PATH) {
    console.error('ERROR: MNEMONIC_PATH not set. Run via lamassu-eth-sweep (installed wrapper).')
    process.exit(1)
  }

  const mnemonic = fs.readFileSync(MNEMONIC_PATH, 'utf8')
  const seed     = computeSeed(mnemonic)

  console.log('Loading server settings...')
  const settings     = await settingsLoader.load()
  const walletPlugin = configManager.getWalletSettings('ETH', settings.config).wallet

  // Connect to Infura or local geth
  if (walletPlugin === 'infura') {
    let ep = settings.accounts.infura.endpoint || ''
    if (!ep.startsWith('https://')) ep = 'https://' + ep
    web3.setProvider(new web3.providers.HttpProvider(ep))
    console.log(`Connected via Infura: ${ep}`)
  } else {
    const { utils: coinUtils } = require('@lamassu/coins')
    const port = coinUtils.getCryptoCurrency('ETH').defaultPort
    web3.setProvider(new web3.providers.HttpProvider(`http://localhost:${port}`))
    console.log(`Connected via local geth: http://localhost:${port}`)
  }

  const hotAddr = hotWallet(seed).getChecksumAddressString()
  console.log(`Hot wallet: ${hotAddr}`)

  // Fetch current gas fees for dust evaluation
  const fees = await getCurrentFees()
  const gasCostWei = fees.maxFeePerGas.times(ETH_TRANSFER_GAS)
  console.log(`Current estimated gas cost per sweep: ${gasCostWei.div(1e18).toFixed(8)} ETH`)

  // Query DB
  console.log('\nQuerying DB for ETH cash-out payment addresses...')
  const rows = await db.manyOrNone(`
    SELECT DISTINCT ON (to_address) to_address, hd_index
    FROM cash_out_txs
    WHERE crypto_code = 'ETH'
      AND to_address IS NOT NULL
      AND hd_index IS NOT NULL
    ORDER BY to_address, created DESC
  `)

  if (!rows || rows.length === 0) {
    console.log('No ETH cash-out addresses found in DB. Exiting.')
    process.exit(0)
  }

  console.log(`Found ${rows.length} address(es) in DB. Checking on-chain balances...\n`)

  const sweepable = []

  for (let i = 0; i < rows.length; i++) {
    const row = rows[i]
    process.stdout.write(`  [${i + 1}/${rows.length}] ${row.to_address} ... `)

    try {
      const balance = await getEthBalance(row.to_address)
      const afterGas = balance.minus(gasCostWei)

      if (balance.gt(DUST_THRESHOLD_WEI) && afterGas.gt(0)) {
        const ethBal   = balance.div(1e18).toFixed(8)
        const ethAfter = afterGas.div(1e18).toFixed(8)
        console.log(`${ethBal} ETH  (after gas: ${ethAfter} ETH)  ← SWEEPABLE`)
        sweepable.push({ address: row.to_address, hdIndex: row.hd_index, balance, afterGas })
      } else {
        const ethBal = balance.div(1e18).toFixed(8)
        console.log(`${ethBal} ETH  (dust or empty, skip)`)
      }
    } catch (err) {
      console.log(`ERROR: ${err.message}`)
    }

    // Small delay between Infura calls
    if (i < rows.length - 1) await delay(350)
  }

  if (sweepable.length === 0) {
    console.log('\nNo addresses with sweepable ETH found. Done.')
    process.exit(0)
  }

  const totalEth = sweepable.reduce((s, a) => s.plus(a.afterGas), BN(0)).div(1e18)

  console.log('\n╔══════════════════════════════════════════════════════════════╗')
  console.log('║                     SWEEP SUMMARY (ETH)                     ║')
  console.log('╠══════════════════════════════════════════════════════════════╣')
  sweepable.forEach((a, i) => {
    const eth = a.afterGas.div(1e18).toFixed(8)
    console.log(`║  [${i + 1}] ${a.address}`)
    console.log(`║      HD index: ${a.hdIndex}  |  Sweepable: ~${eth} ETH`)
  })
  console.log('╠══════════════════════════════════════════════════════════════╣')
  console.log(`║  Total: ${sweepable.length} address(es)  |  ~${totalEth.toFixed(8)} ETH → hot wallet`)
  console.log('╚══════════════════════════════════════════════════════════════╝\n')

  const answer = await prompt('Sweep all of the above to the hot wallet? [y/N] ')
  if (answer !== 'y') {
    console.log('Aborted. No funds moved.')
    process.exit(0)
  }

  // Refresh fees just before sending
  const freshFees = await getCurrentFees()

  console.log('\nStarting sweep...\n')
  let ok = 0, fail = 0

  for (const addr of sweepable) {
    console.log(`Sweeping ${addr.address} (HD index: ${addr.hdIndex})...`)
    try {
      const wallet         = paymentWallet(seed, addr.hdIndex)
      const currentBalance = await getEthBalance(addr.address)

      if (currentBalance.eq(0)) {
        console.log('  Balance is now 0, skipping.\n')
        continue
      }

      const rawTx  = await buildSweepTx(wallet, hotAddr, currentBalance, freshFees)
      const txHash = await sendRaw(rawTx)
      console.log(`  ✓ Sent. TxHash: ${txHash}\n`)
      ok++
    } catch (err) {
      console.error(`  ✗ Error: ${err.message}\n`)
      fail++
    }

    await delay(2000) // 2s between txs — Infura safety
  }

  console.log(`=== Done. Swept: ${ok}, Failed: ${fail} ===`)
  process.exit(0)
}

main().catch(err => {
  console.error('\nFatal error:', err.message)
  process.exit(1)
})
NODEJS_SCRIPT

# ---- Write the launcher at /usr/local/bin ------------------------------------
cat > "$BIN_PATH" << 'LAUNCHER'
#!/bin/bash
# lamassu-eth-sweep — launcher installed by deploy-eth-sweep.sh
set -e

SERVER_ROOT="/usr/lib/node_modules/lamassu-server"
SCRIPT_PATH="/opt/lamassu-tools/eth-cashout-sweep.js"

if [ "$EUID" -ne 0 ]; then
  echo "ERROR: Please run as root: sudo lamassu-eth-sweep"
  exit 1
fi

# Source server env (sets MNEMONIC_PATH, POSTGRES_* etc)
set -a
source "$SERVER_ROOT/.env"
set +a

# cd to server root so node resolves modules from its own node_modules
cd "$SERVER_ROOT"

exec node "$SCRIPT_PATH"
LAUNCHER

chmod +x "$BIN_PATH"

# ---- Done -------------------------------------------------------------------
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║       lamassu-eth-sweep installed successfully       ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Script:    /opt/lamassu-tools/eth-cashout-sweep.js  ║"
echo "║  Command:   sudo lamassu-eth-sweep                   ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Run it now with:  sudo lamassu-eth-sweep"
