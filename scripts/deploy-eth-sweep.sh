#!/bin/bash
# Installs the ETH cash-out sweep tool onto the Lamassu server.
# curl -sS https://raw.githubusercontent.com/Lamatos/lamassu-patches/refs/heads/master/scripts/deploy-eth-sweep.sh | bash

cat > /usr/lib/node_modules/lamassu-server/eth-cashout-sweep.js << 'EOF'
#!/usr/bin/env node
/**
 * eth-cashout-sweep.js
 *
 * Queries the DB for ETH cash-out payment addresses where a payment was
 * actually detected, checks their on-chain balances in batches of 50 per
 * Infura request), and sweeps non-dust balances to the hot wallet.
 *
 * Run with:
 *   node /usr/lib/node_modules/lamassu-server/eth-cashout-sweep.js
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

const PAYMENT_PREFIX_PATH  = "m/44'/60'/0'/0'"
const DEFAULT_PREFIX_PATH  = "m/44'/60'/1'/0'"
const ETH_TRANSFER_GAS     = 21000
const CHAIN_ID             = 1
const DUST_THRESHOLD_WEI   = BN('1000000000000000') // 0.001 ETH

const BATCH_SIZE      = 50
const BATCH_DELAY_MS  = 5000
const SWEEP_DELAY_MS  = 2000

const MNEMONIC_PATH = process.env.MNEMONIC_PATH
const web3 = new Web3()
let lastUsedNonces = {}

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

function getBalancesBatch(addresses) {
  return new Promise((resolve) => {
    const results   = addresses.map(() => BN(0))
    let completed   = 0

    const batch = new web3.BatchRequest()

    addresses.forEach((address, i) => {
      batch.add(
        web3.eth.getBalance.request(address.toLowerCase(), 'latest', (err, balance) => {
          results[i] = err ? BN(0) : BN(balance || 0)
          completed++
          if (completed === addresses.length) resolve(results)
        })
      )
    })

    batch.execute()
  })
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
  const txCount     = await web3.eth.getTransactionCount(fromAddress)
  const nonce       = _.max([0, txCount, (lastUsedNonces[fromAddress] || -1) + 1])
  lastUsedNonces[fromAddress] = nonce

  const gas    = BN(ETH_TRANSFER_GAS)
  const fee    = fees.maxFeePerGas.times(gas)
  const toSend = balance.minus(fee)

  if (toSend.lte(0)) throw new Error(`Balance cannot cover gas fee`)

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

async function main() {
  if (!MNEMONIC_PATH) {
    console.error('ERROR: MNEMONIC_PATH not set.')
    process.exit(1)
  }

  const mnemonic = fs.readFileSync(MNEMONIC_PATH, 'utf8')
  const seed     = computeSeed(mnemonic)

  console.log('Loading server settings...')
  const settings     = await settingsLoader.load()
  const walletPlugin = configManager.getWalletSettings('ETH', settings.config).wallet

  if (walletPlugin === 'infura') {
    let ep = settings.accounts.infura.endpoint || ''
    if (!ep.startsWith('https://')) ep = 'https://' + ep
    web3.setProvider(new web3.providers.HttpProvider(ep))
    console.log(`Connected via Infura`)
  } else {
    const { utils: coinUtils } = require('@lamassu/coins')
    const port = coinUtils.getCryptoCurrency('ETH').defaultPort
    web3.setProvider(new web3.providers.HttpProvider(`http://localhost:${port}`))
    console.log(`Connected via local geth`)
  }

  const hotAddr = hotWallet(seed).getChecksumAddressString()
  console.log(`Hot wallet: ${hotAddr}`)

  const fees       = await getCurrentFees()
  const gasCostWei = fees.maxFeePerGas.times(ETH_TRANSFER_GAS)
  console.log(`Estimated gas cost per sweep: ${gasCostWei.div(1e18).toFixed(8)} ETH`)

  console.log('\nQuerying DB for ETH cash-out payment addresses...')
  const rows = await db.manyOrNone(`
    SELECT DISTINCT ON (to_address) to_address, hd_index
    FROM cash_out_txs
    WHERE crypto_code = 'ETH'
      AND to_address IS NOT NULL
      AND hd_index IS NOT NULL
      AND (
        status != 'notSeen'
        OR created > NOW() - INTERVAL '7 days'
      )
    ORDER BY to_address, created DESC
  `)

  if (!rows || rows.length === 0) {
    console.log('No addresses to check.')
    process.exit(0)
  }

  const totalBatches = Math.ceil(rows.length / BATCH_SIZE)
  console.log(`Found ${rows.length} candidate address(es) — checking in ${totalBatches} batch(es) of ${BATCH_SIZE}...\n`)

  // ── Batch balance check ───────────────────────────────────────────────────
  const sweepable = []

  for (let i = 0; i < rows.length; i += BATCH_SIZE) {
    const batchRows   = rows.slice(i, i + BATCH_SIZE)
    const batchNum    = Math.floor(i / BATCH_SIZE) + 1
    const addresses   = batchRows.map(r => r.to_address)

    process.stdout.write(`  Batch ${batchNum}/${totalBatches} (${addresses.length} addresses) ... `)

    try {
      const balances = await getBalancesBatch(addresses)

      let found = 0
      balances.forEach((balance, j) => {
        const afterGas = balance.minus(gasCostWei)
        if (balance.gt(DUST_THRESHOLD_WEI) && afterGas.gt(0)) {
          sweepable.push({
            address: batchRows[j].to_address,
            hdIndex: batchRows[j].hd_index,
            balance,
            afterGas,
          })
          found++
        }
      })

      console.log(`done  (${found} sweepable, ${sweepable.length} total so far)`)
    } catch (err) {
      console.log(`ERROR: ${err.message}`)
    }

    if (i + BATCH_SIZE < rows.length) await delay(BATCH_DELAY_MS)
  }

  if (sweepable.length === 0) {
    console.log('\nNothing to sweep.')
    process.exit(0)
  }

  const totalEth = sweepable.reduce((s, a) => s.plus(a.afterGas), BN(0)).div(1e18)
  console.log(`\nFound ${sweepable.length} address(es) with ~${totalEth.toFixed(8)} ETH total -> ${hotAddr}`)

  const answer = await prompt('\nSweep all to the hot wallet? [y/N] ')
  if (answer !== 'y') {
    console.log('Aborted.')
    process.exit(0)
  }

  // ── Sweep ─────────────────────────────────────────────────────────────────
  const freshFees = await getCurrentFees()
  let ok = 0, fail = 0

  for (const addr of sweepable) {
    console.log(`\nSweeping ${addr.address} (HD index: ${addr.hdIndex})...`)
    try {
      const wallet         = paymentWallet(seed, addr.hdIndex)
      const currentBalance = await getBalancesBatch([addr.address]).then(r => r[0])
      if (currentBalance.eq(0)) { console.log('  Balance is 0 now, skipping.'); continue }
      const rawTx  = await buildSweepTx(wallet, hotAddr, currentBalance, freshFees)
      const txHash = await sendRaw(rawTx)
      console.log(`  Done. TxHash: ${txHash}`)
      ok++
    } catch (err) {
      console.error(`  Error: ${err.message}`)
      fail++
    }
    await delay(SWEEP_DELAY_MS)
  }

  console.log(`\nDone. Swept: ${ok}, Failed: ${fail}`)
  process.exit(0)
}

main().catch(err => {
  console.error('Fatal:', err.message)
  process.exit(1)
})
EOF

echo "Done. Run with: node /usr/lib/node_modules/lamassu-server/eth-cashout-sweep.js"
