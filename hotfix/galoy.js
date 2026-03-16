const _ = require('lodash/fp')
const axios = require('axios')
const { utils: coinUtils } = require('@lamassu/coins')

const NAME = 'LN'
const SUPPORTED_COINS = ['LN']

const BN = require('../../../bn')

function request(graphqlQuery, token, endpoint) {
  const headers = {
    'content-type': 'application/json',
    'X-API-KEY': token,
  }
  return axios({
    method: 'post',
    url: endpoint,
    headers: headers,
    data: graphqlQuery,
  })
    .then(r => {
      if (r.error) throw r.error
      return r.data
    })
    .catch(err => {
      throw new Error(err)
    })
}

function checkCryptoCode(cryptoCode) {
  if (!SUPPORTED_COINS.includes(cryptoCode)) {
    return Promise.reject(new Error('Unsupported crypto: ' + cryptoCode))
  }

  return Promise.resolve()
}

function getTransactionsByAddress(token, endpoint, walletId, address) {
  const accountInfo = {
    operationName: 'me',
    query: `query me($walletId: WalletId!, , $address: OnChainAddress!) {
      me {
        defaultAccount {
          walletById(walletId: $walletId) {
            transactionsByAddress (address: $address) {
              edges {
                node {
                  direction
                  settlementAmount
                  status
                }
              }
            }
          }
        }
      }
    }`,
    variables: { walletId, address },
  }
  return request(accountInfo, token, endpoint)
    .then(r => {
      return r.data.me.defaultAccount.walletById.transactionsByAddress
    })
    .catch(err => {
      throw new Error(err)
    })
}

function getGaloyWallet(token, endpoint, walletId) {
  const accountInfo = {
    operationName: 'me',
    query: `query me($walletId: WalletId!) {
      me {
        defaultAccount {
          walletById(walletId: $walletId) {
            id
            walletCurrency
            balance
          }
        }
      }
    }`,
    variables: { walletId },
  }
  return request(accountInfo, token, endpoint)
    .then(r => {
      return r.data.me.defaultAccount.walletById
    })
    .catch(err => {
      throw new Error(err)
    })
}

function isLnInvoice(address) {
  return address.toLowerCase().startsWith('lnbc')
}

function isLnurl(address) {
  return address.toLowerCase().startsWith('lnurl')
}

function sendFundsOnChain(walletId, address, cryptoAtoms, token, endpoint) {
  const sendOnChain = {
    operationName: 'onChainPaymentSend',
    query: `mutation onChainPaymentSend($input: OnChainPaymentSendInput!) {
      onChainPaymentSend(input: $input) {
        errors {
          message
          path
        }
        status
      }
    }`,
    variables: { input: { address, amount: cryptoAtoms.toString(), walletId } },
  }
  return request(sendOnChain, token, endpoint).then(result => {
    return result.data.onChainPaymentSend
  })
}

function sendFundsLNURL(walletId, lnurl, cryptoAtoms, token, endpoint) {
  const sendLnNoAmount = {
    operationName: 'lnurlPaymentSend',
    query: `mutation lnurlPaymentSend($input: LnurlPaymentSendInput!) {
      lnurlPaymentSend(input: $input) {
        errors {
          message
          path
        }
        status
      }
    }`,
    variables: {
      input: {
        lnurl: `${lnurl}`,
        walletId: `${walletId}`,
        amount: `${cryptoAtoms}`,
      },
    },
  }
  return request(sendLnNoAmount, token, endpoint).then(
    result => result.data.lnurlPaymentSend,
  )
}

function sendFundsLN(walletId, invoice, cryptoAtoms, token, endpoint) {
  const sendLnNoAmount = {
    operationName: 'lnNoAmountInvoicePaymentSend',
    query: `mutation lnNoAmountInvoicePaymentSend($input: LnNoAmountInvoicePaymentInput!) {
      lnNoAmountInvoicePaymentSend(input: $input) {
        errors {
          message
          path
        }
        status
      }
    }`,
    variables: {
      input: {
        paymentRequest: invoice,
        walletId,
        amount: cryptoAtoms.toString(),
      },
    },
  }
  return request(sendLnNoAmount, token, endpoint).then(
    result => result.data.lnNoAmountInvoicePaymentSend,
  )
}

function sendProbeRequest(walletId, invoice, cryptoAtoms, token, endpoint) {
  const sendProbeNoAmount = {
    operationName: 'lnNoAmountInvoiceFeeProbe',
    query: `mutation lnNoAmountInvoiceFeeProbe($input: LnNoAmountInvoiceFeeProbeInput!) {
      lnNoAmountInvoiceFeeProbe(input: $input) {
        amount
        errors {
          message
          path
        }
      }
    }`,
    variables: {
      input: {
        paymentRequest: invoice,
        walletId,
        amount: cryptoAtoms.toString(),
      },
    },
  }
  return request(sendProbeNoAmount, token, endpoint).then(
    result => result.data.lnNoAmountInvoiceFeeProbe,
  )
}

// FIX: Before attempting a real payment, probe the route and wait for it to
// become available. LN routes can take a moment to be established — if the
// machine sends immediately after scanning, Galoy often returns FAILURE because
// no route is ready yet. This retries the probe up to MAX_PROBE_ATTEMPTS times
// with increasing delays, giving the network time to find a path.
const MAX_PROBE_ATTEMPTS = 5
const PROBE_INITIAL_DELAY_MS = 1500 // wait 1.5s before first probe
const PROBE_BACKOFF_MS = 2000       // add 2s for each subsequent attempt

function waitForRoute(walletId, invoice, cryptoAtoms, token, endpoint) {
  function attempt(triesLeft, delayMs) {
    return new Promise(resolve => setTimeout(resolve, delayMs))
      .then(() => sendProbeRequest(walletId, invoice, cryptoAtoms, token, endpoint))
      .then(result => {
        const hasRoute = _.isEmpty(result.errors)
        if (hasRoute) return true
        if (triesLeft <= 1) {
          console.log('[LN] Route not found after all probe attempts, will try payment anyway')
          return false
        }
        console.log(`[LN] Route not ready, retrying probe (${triesLeft - 1} attempts left)...`)
        return attempt(triesLeft - 1, PROBE_BACKOFF_MS)
      })
      .catch(err => {
        console.log('[LN] Probe request failed:', err.message)
        return false
      })
  }
  return attempt(MAX_PROBE_ATTEMPTS, PROBE_INITIAL_DELAY_MS)
}

function sendCoins(account, tx) {
  const { toAddress, cryptoAtoms, cryptoCode } = tx
  return checkCryptoCode(cryptoCode)
    .then(() => {
      if (isLnInvoice(toAddress)) {
        return waitForRoute(
          account.walletId,
          toAddress,
          cryptoAtoms,
          account.apiSecret,
          account.endpoint,
        ).then(() => sendFundsLN(
          account.walletId,
          toAddress,
          cryptoAtoms,
          account.apiSecret,
          account.endpoint,
        ))
      }
      if (isLnurl(toAddress)) {
        return sendFundsLNURL(
          account.walletId,
          toAddress,
          cryptoAtoms,
          account.apiSecret,
          account.endpoint,
        )
      }
      return sendFundsOnChain(
        account.walletId,
        toAddress,
        cryptoAtoms,
        account.apiSecret,
        account.endpoint,
      )
    })
    .then(result => {
      switch (result.status) {
        case 'ALREADY_PAID':
          throw new Error('Transaction already exists!')
        case 'FAILURE':
          throw new Error('Transaction failed!', JSON.stringify(result.errors))
        case 'SUCCESS':
          return '<galoy transaction>'
        case 'PENDING':
          return '<galoy transaction>'
        default:
          throw new Error(
            `Transaction failed: ${_.head(result.errors).message}`,
          )
      }
    })
}

function probeLN(account, cryptoCode, invoice) {
  const probeHardLimits = [200000, 1000000, 2000000]
  const promises = probeHardLimits.map(limit => {
    return sendProbeRequest(
      account.walletId,
      invoice,
      limit,
      account.apiSecret,
      account.endpoint,
    ).then(r => _.isEmpty(r.errors))
  })
  return Promise.all(promises).then(results =>
    _.zipObject(probeHardLimits, results),
  )
}

function newOnChainAddress(walletId, token, endpoint) {
  const createOnChainAddress = {
    operationName: 'onChainAddressCreate',
    query: `mutation onChainAddressCreate($input: OnChainAddressCreateInput!) {
      onChainAddressCreate(input: $input) {
        address
        errors {
          message
          path
        }
      }
    }`,
    variables: { input: { walletId } },
  }
  return request(createOnChainAddress, token, endpoint).then(result => {
    return result.data.onChainAddressCreate.address
  })
}

function newInvoice(walletId, cryptoAtoms, token, endpoint) {
  const createInvoice = {
    operationName: 'lnInvoiceCreate',
    query: `mutation lnInvoiceCreate($input: LnInvoiceCreateInput!) {
      lnInvoiceCreate(input: $input) {
        errors {
          message
          path
        }
        invoice {
          paymentRequest
        }
      }
    }`,
    variables: { input: { walletId, amount: cryptoAtoms.toString() } },
  }
  return request(createInvoice, token, endpoint).then(result => {
    return result.data.lnInvoiceCreate.invoice.paymentRequest
  })
}

function balance(account, cryptoCode) {
  return checkCryptoCode(cryptoCode)
    .then(() =>
      getGaloyWallet(account.apiSecret, account.endpoint, account.walletId),
    )
    .then(wallet => {
      return new BN(wallet.balance || 0)
    })
}

function newAddress(account, info, tx) {
  const { cryptoAtoms, cryptoCode } = tx
  return checkCryptoCode(cryptoCode).then(() =>
    newInvoice(
      account.walletId,
      cryptoAtoms,
      account.apiSecret,
      account.endpoint,
    ),
  )
}

function getInvoiceStatus(token, endpoint, address) {
  const query = {
    operationName: 'lnInvoicePaymentStatus',
    query: `query lnInvoicePaymentStatus($input: LnInvoicePaymentStatusInput!) {
      lnInvoicePaymentStatus(input: $input) {
        status
      }
    }`,
    variables: { input: { paymentRequest: address } },
  }
  return request(query, token, endpoint)
    .then(r => {
      return r?.data?.lnInvoicePaymentStatus?.status
    })
    .catch(err => {
      throw new Error(err)
    })
}

function getStatus(account, tx, requested) {
  const { toAddress, cryptoAtoms, cryptoCode } = tx
  const getBalance = _.reduce(
    (acc, value) => {
      acc[value.node.status] = acc[value.node.status].plus(
        new BN(value.node.settlementAmount),
      )
      return acc
    },
    { SUCCESS: new BN(0), PENDING: new BN(0), FAILURE: new BN(0) },
  )

  return checkCryptoCode(cryptoCode).then(() => {
    const address = coinUtils.parseUrl(
      cryptoCode,
      account.environment,
      toAddress,
      false,
    )
    if (isLnInvoice(address)) {
      return getInvoiceStatus(
        account.apiSecret,
        account.endpoint,
        address,
      ).then(it => {
        const isPaid = it === 'PAID'
        if (isPaid)
          return { receivedCryptoAtoms: cryptoAtoms, status: 'confirmed' }
        return { receivedCryptoAtoms: BN(0), status: 'notSeen' }
      })
    }
    // On-chain and intra-ledger transactions
    return getTransactionsByAddress(
      account.apiSecret,
      account.endpoint,
      account.walletId,
      address,
    ).then(transactions => {
      const { SUCCESS: confirmed, PENDING: pending } = getBalance(
        transactions.edges,
      )
      if (confirmed.gte(requested))
        return { receivedCryptoAtoms: confirmed, status: 'confirmed' }
      if (pending.gte(requested))
        return { receivedCryptoAtoms: pending, status: 'authorized' }
      if (pending.gt(0))
        return { receivedCryptoAtoms: pending, status: 'insufficientFunds' }
      return { receivedCryptoAtoms: pending, status: 'notSeen' }
    })
  })
}

function newFunding(account, cryptoCode) {
  // Regular BTC address
  return checkCryptoCode(cryptoCode)
    .then(() =>
      getGaloyWallet(account.apiSecret, account.endpoint, account.walletId),
    )
    .then(wallet => {
      return newOnChainAddress(
        account.walletId,
        account.apiSecret,
        account.endpoint,
      ).then(onChainAddress => [onChainAddress, wallet.balance])
    })
    .then(([onChainAddress, balance]) => {
      return {
        // with the old api is not possible to get pending balance
        fundingPendingBalance: new BN(0),
        fundingConfirmedBalance: new BN(balance),
        fundingAddress: onChainAddress,
      }
    })
}

function cryptoNetwork(account, cryptoCode) {
  return checkCryptoCode(cryptoCode).then(() =>
    account.environment === 'test' ? 'test' : 'main',
  )
}

function checkBlockchainStatus(cryptoCode) {
  return checkCryptoCode(cryptoCode).then(() => Promise.resolve('ready'))
}

module.exports = {
  NAME,
  balance,
  sendCoins,
  newAddress,
  getStatus,
  newFunding,
  cryptoNetwork,
  checkBlockchainStatus,
  probeLN,
}
