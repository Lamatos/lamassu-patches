const axios = require('axios')
const _ = require('lodash/fp')

const NAME = 'Chainalysis'
const SUPPORTED_COINS = {
  BTC: 'BITCOIN',
  ETH: 'ETHEREUM',
  USDT: 'ETHEREUM',
  BCH: 'BITCOINCASH',
  LTC: 'LITECOIN',
  DASH: 'DASH', // Verify Chainalysis support
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

    const threshold = account.scoreThreshold

    // MAPPING: Use the existing Scorechain configuration fields for Chainalysis credentials
    // account.apiKey -> Chainalysis Key
    // account.url -> Chainalysis URL (if customizable) or default

    const headers = {
      accept: 'application/json',
      'Token': account.apiKey, // Chainalysis usually uses 'Token' or 'X-API-Key' depending on product. Adjust if needed.
      'Content-Type': 'application/json',
    }

    // This is a GENERIC implementation for Chainalysis KYT.
    // You may need to adjust the endpoint '/api/kyt/v2/users/{userId}/transfers' or specific screening endpoint depending on your license.
    // For this example, we assume a direct 'screen address' style endpoint or similar.
    // IF Chainalysis doesn't have a direct 'score 0-100' API, we map alerts to a score.

    // EXAMPLE: Screen an Address
    const url = `https://api.chainalysis.com/api/risk/v2/entities/${objectId}` 
    
    // NOTE: If you need to post a specific payload for screening:
    // const payload = { address: objectId, asset: SUPPORTED_COINS[cryptoCode] }
    
    // Returning a MOCK implementation structure that you must adapt to the real API response
    return axios
      .get(url, { headers })
      .then(res => {
        // ADAPTATION REQUIRED HERE:
        // Parse the response to find a risk level.
        // Example: res.data.risk === 'High' -> Score 0
        // Example: res.data.risk === 'Low' -> Score 100
        
        const riskLevel = res.data.risk // This path is hypothetical. Verify with your API Docs.
        
        let calculatedScore = 100
        if (riskLevel === 'Severe') calculatedScore = 0
        if (riskLevel === 'High') calculatedScore = 25
        if (riskLevel === 'Medium') calculatedScore = 50
        if (riskLevel === 'Low') calculatedScore = 100

        // If specific numeric score is returned, use it directly after normalization:
        // const resScore = res.data.score
        
        return { score: (100 - calculatedScore) / 10, isValid: calculatedScore >= threshold }
      })
      .catch(err => {
        console.error('Chainalysis API Error:', err.message)
        // Only throw if you want to block the trade on error. 
        // Otherwise return null to fail-open (allow trade) or throw to fail-closed.
        throw new Error('Failed to get score from Chainalysis API') 
      })
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
