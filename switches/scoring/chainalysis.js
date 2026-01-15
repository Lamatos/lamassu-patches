const axios = require('axios')
const _ = require('lodash/fp')

const NAME = 'Chainalysis'

// Mapping of Lamassu crypto codes to Chainalysis network identifiers if needed.
// Note: The V2 entities endpoint does not explicitly require a network parameter for all lookups,
// but if we need to filter or specify, we can use this map.
const SUPPORTED_COINS = {
  BTC: 'BITCOIN',
  ETH: 'ETHEREUM',
  USDT: 'ETHEREUM',
  BCH: 'BITCOINCASH',
  LTC: 'LITECOIN',
  DASH: 'DASH',
  TRX: 'TRON',
  USDT_TRON: 'TRON',
}

const TYPE = {
  TRANSACTION: 'TRANSACTION',
  ADDRESS: 'ADDRESS',
}

function rate(account, objectType, cryptoCode, objectId) {
  return isWalletScoringEnabled(account, cryptoCode).then(isEnabled => {
    if (!isEnabled) return Promise.resolve(null)

    // Configuration
    const apiKey = account.apiKey
    const threshold = account.scoreThreshold

    // Headers
    const headers = {
      accept: 'application/json',
      'Token': apiKey,
    }

    // -- ADDRESS SCREENING --
    if (objectType === TYPE.ADDRESS) {
      // Endpoint: GET https://api.chainalysis.com/api/risk/v2/entities/{address}
      const url = `https://api.chainalysis.com/api/risk/v2/entities/${objectId}`

      return axios.get(url, { headers })
        .then(res => {
          const data = res.data
          const riskLevel = data.risk // 'Low', 'Medium', 'High', 'Severe'

          // Map Risk Level to a "Safety Score" (0-100) where 100 is Safe.
          // This creates compatibility with the Scorechain plugin logic.
          let safetyScore = 100 // Default to safe if unknown? Or 0? Assuming Low risk default.

          switch (riskLevel) {
            case 'Low':
              safetyScore = 100
              break
            case 'Medium':
              safetyScore = 66
              break
            case 'High':
              safetyScore = 33
              break
            case 'Severe':
              safetyScore = 0
              break
            default:
              // Handle unknown or 'None' as Low risk, or log warning?
              // Chainalysis might return other statuses but Enum says: Low, Medium, High, Severe.
              safetyScore = 100
              console.log(`[Chainalysis] Unknown risk level: ${riskLevel} for ${objectId}. Treating as Low risk.`)
          }

          // Logic from scorechain.js:
          // score: (100 - resScore) / 10  -> Means 0 is Lowest Risk, 10 is Highest Risk.
          // isValid: resScore >= threshold -> Means Higher Safety Score is Valid.

          const normalizedScore = (100 - safetyScore) / 10
          const isValid = safetyScore >= threshold

          return { score: normalizedScore, isValid }
        })
        .catch(err => {
          // Identify 404
          if (err.response && err.response.status === 404) {
            // Address not found often means no risk history -> Low Risk
            return { score: 0, isValid: true }
          }
          console.error('[Chainalysis] API Error:', err.message)
          // If we can't score, deciding whether to fail open or closed.
          // Throwing error usually stops the flow.
          throw new Error('Failed to get score from Chainalysis API')
        })
    }

    // -- TRANSACTION SCREENING --
    if (objectType === TYPE.TRANSACTION) {
      // Transaction screening is not required by the user at this stage.
      // We return null to indicate "no scoring performed" (fail-open/neutral).
      return Promise.resolve(null)
    }

    return Promise.resolve(null)
  })
}

function rateTransaction(account, cryptoCode, transactionId) {
  return rate(account, TYPE.TRANSACTION, cryptoCode, transactionId)
}

function rateAddress(account, cryptoCode, address) {
  return rate(account, TYPE.ADDRESS, cryptoCode, address)
}

function isWalletScoringEnabled(account, cryptoCode) {
  const isAccountEnabled = !_.isNil(account) && account.enabled

  if (!isAccountEnabled) return Promise.resolve(false)

  if (!Object.keys(SUPPORTED_COINS).includes(cryptoCode)) {
    return Promise.reject(new Error('Unsupported crypto: ' + cryptoCode))
  }

  return Promise.resolve(true)
}

module.exports = {
  NAME,
  rateAddress,
  rateTransaction,
  isWalletScoringEnabled,
}
