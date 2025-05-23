const _ = require('lodash/fp')
const crypto = require('crypto')
const pgp = require('pg-promise')()
const { getTimezoneOffset } = require('date-fns-tz')
const { millisecondsToMinutes } = require('date-fns/fp')

const BN = require('./bn')
const dbm = require('./postgresql_interface')
const db = require('./db')
const logger = require('./logger')
const logs = require('./logs')
const T = require('./time')
const configManager = require('./new-config-manager')
const settingsLoader = require('./new-settings-loader')
const ticker = require('./ticker')
const wallet = require('./wallet')
const walletScoring = require('./wallet-scoring')
const exchange = require('./exchange')
const sms = require('./sms')
const email = require('./email')
const cashOutHelper = require('./cash-out/cash-out-helper')
const machineLoader = require('./machine-loader')
const commissionMath = require('./commission-math')
const loyalty = require('./loyalty')
const transactionBatching = require('./tx-batching')

const {
  CASH_OUT_DISPENSE_READY,
  CASH_OUT_MAXIMUM_AMOUNT_OF_CASSETTES,
  CASH_OUT_MAXIMUM_AMOUNT_OF_RECYCLERS,
  CASH_UNIT_CAPACITY,
  CONFIRMATION_CODE,
} = require('./constants')

const notifier = require('./notifier')

const { utils: coinUtils } = require('@lamassu/coins')

const mapValuesWithKey = _.mapValues.convert({
  cap: false
})

const TRADE_TTL = 2 * T.minutes
const STALE_TICKER = 3 * T.minutes
const STALE_BALANCE = 3 * T.minutes
const tradesQueues = {}

function plugins (settings, deviceId) {

  function internalBuildRates (tickers, withCommission = true) {
    const localeConfig = configManager.getLocale(deviceId, settings.config)
    const cryptoCodes = localeConfig.cryptoCurrencies

    const rates = {}

    cryptoCodes.forEach((cryptoCode, i) => {
      const rateRec = tickers[i]
      const commissions = configManager.getCommissions(cryptoCode, deviceId, settings.config)

      if (!rateRec) return

      const cashInCommission = new BN(1).plus(new BN(commissions.cashIn).div(100))

      const cashOutCommission = _.isNil(commissions.cashOut)
        ? undefined
        : new BN(1).plus(new BN(commissions.cashOut).div(100))

      if (Date.now() - rateRec.timestamp > STALE_TICKER) return logger.warn('Stale rate for ' + cryptoCode)
      const rate = rateRec.rates

      withCommission ? rates[cryptoCode] = {
        cashIn: rate.ask.times(cashInCommission).decimalPlaces(5),
        cashOut: cashOutCommission && rate.bid.div(cashOutCommission).decimalPlaces(5)
      } : rates[cryptoCode] = {
        cashIn: rate.ask.decimalPlaces(5),
        cashOut: rate.bid.decimalPlaces(5)
      }
    })
    return rates
  }

  function buildRatesNoCommission (tickers) {
    return internalBuildRates(tickers, false)
  }

  function buildRates (tickers) {
    return internalBuildRates(tickers, true)
  }

  function getNotificationConfig () {
    return configManager.getGlobalNotifications(settings.config)
  }

  function buildBalances (balanceRecs) {
    const localeConfig = configManager.getLocale(deviceId, settings.config)
    const cryptoCodes = localeConfig.cryptoCurrencies

    const balances = {}

    cryptoCodes.forEach((cryptoCode, i) => {
      const balanceRec = balanceRecs[i]
      if (!balanceRec) return logger.warn('No balance for ' + cryptoCode + ' yet')
      if (Date.now() - balanceRec.timestamp > STALE_BALANCE) return logger.warn('Stale balance for ' + cryptoCode)

      balances[cryptoCode] = balanceRec.balance
    })

    return balances
  }

  function isZeroConf (tx) {
    const walletSettings = configManager.getWalletSettings(tx.cryptoCode, settings.config)
    const zeroConfLimit = walletSettings.zeroConfLimit || 0
    return tx.fiat.lte(zeroConfLimit)
  }

  const accountProvisioned = (cashUnitType, cashUnits, redeemableTxs) => {
    const kons = (cashUnits, tx) => {
      // cash-out-helper sends 0 as fallback value, need to filter it out as there are no '0' denominations
      const cashUnitsBills = _.flow(
        _.get(['bills']),
        _.filter(it => _.includes(cashUnitType, it.name) && it.denomination > 0),
        _.zip(cashUnits),
      )(tx)

      const sameDenominations = ([cashUnit, bill]) => cashUnit?.denomination === bill?.denomination
      if (!_.every(sameDenominations, cashUnitsBills))
        throw new Error(`Denominations don't add up, ${cashUnitType}s were changed.`)

      return _.map(
        ([cashUnit, { provisioned }]) => _.set('count', cashUnit.count - provisioned, cashUnit),
        cashUnitsBills
      )
    }

    return _.reduce(kons, cashUnits, redeemableTxs)
  }

  function computeAvailableCassettes (cassettes, redeemableTxs) {
    if (_.isEmpty(redeemableTxs)) return cassettes
    cassettes = accountProvisioned('cassette', cassettes, redeemableTxs)
    if (_.some(({ count }) => count < 0, cassettes))
      throw new Error('Negative note count: %j', counts)
    return cassettes
  }

  function computeAvailableRecyclers (recyclers, redeemableTxs) {
    if (_.isEmpty(redeemableTxs)) return recyclers
    recyclers = accountProvisioned('recycler', recyclers, redeemableTxs)
    if (_.some(({ count }) => count < 0, recyclers))
      throw new Error('Negative note count: %j', counts)
    return recyclers
  }

  function buildAvailableCassettes (excludeTxId) {
    const cashOutConfig = configManager.getCashOut(deviceId, settings.config)

    if (!cashOutConfig.active) return Promise.resolve()

    return Promise.all([dbm.cassetteCounts(deviceId), cashOutHelper.redeemableTxs(deviceId, excludeTxId)])
      .then(([{ counts, numberOfCassettes }, redeemableTxs]) => {
        redeemableTxs = _.reject(_.matchesProperty('id', excludeTxId), redeemableTxs)

        const denominations = _.map(
          it => cashOutConfig[`cassette${it}`],
          _.range(1, numberOfCassettes+1)
        )
    
        if (counts.length !== denominations.length)
          throw new Error('Denominations and respective counts do not match!')

        const cassettes = _.map(
          it => ({
            name: `cassette${it + 1}`,
            denomination: parseInt(denominations[it], 10),
            count: parseInt(counts[it], 10)
          }),
          _.range(0, numberOfCassettes)
        )

        const virtualCassettes = denominations.length ? [Math.max(...denominations) * 2] : []

        try {
          return {
            cassettes: computeAvailableCassettes(cassettes, redeemableTxs),
            virtualCassettes
          }
        } catch (err) {
          logger.error(err)
          return {
            cassettes,
            virtualCassettes
          }
        }
      })
  }

  function buildAvailableRecyclers (excludeTxId) {
    const cashOutConfig = configManager.getCashOut(deviceId, settings.config)

    if (!cashOutConfig.active) return Promise.resolve()

    return Promise.all([dbm.recyclerCounts(deviceId), cashOutHelper.redeemableTxs(deviceId, excludeTxId)])
      .then(([{ counts, numberOfRecyclers }, redeemableTxs]) => {
        redeemableTxs = _.reject(_.matchesProperty('id', excludeTxId), redeemableTxs)

        const denominations = _.map(
          it => cashOutConfig[`recycler${it}`],
          _.range(1, numberOfRecyclers+1)
        )

        if (counts.length !== denominations.length)
          throw new Error('Denominations and respective counts do not match!')

        const recyclers = _.map(
          it => ({
            number: it + 1,
            name: `recycler${it + 1}`,
            denomination: parseInt(denominations[it], 10),
            count: parseInt(counts[it], 10)
          }),
          _.range(0, numberOfRecyclers)
        )

        const virtualRecyclers = denominations.length ? [Math.max(..._.flatten(denominations)) * 2] : []

        try {
          return {
            recyclers: computeAvailableRecyclers(recyclers, redeemableTxs),
            virtualRecyclers
          }
        } catch (err) {
          logger.error(err)
          return {
            recyclers,
            virtualRecyclers
          }
        }
      })
  }

  function buildAvailableUnits (excludeTxId) {
    return Promise.all([buildAvailableCassettes(excludeTxId), buildAvailableRecyclers(excludeTxId)])
      .then(([cassettes, recyclers]) => ({ cassettes: cassettes.cassettes, recyclers: recyclers.recyclers }))
  }

  function mapCoinSettings (coinParams) {
    const [ cryptoCode, cryptoNetwork ] = coinParams
    const commissions = configManager.getCommissions(cryptoCode, deviceId, settings.config)
    const minimumTx = new BN(commissions.minimumTx)
    const cashInFee = new BN(commissions.fixedFee)
    const cashOutFee = new BN(commissions.cashOutFixedFee)
    const cashInCommission = new BN(commissions.cashIn)
    const cashOutCommission = _.isNumber(commissions.cashOut) ? new BN(commissions.cashOut) : null
    const cryptoRec = coinUtils.getCryptoCurrency(cryptoCode)
    const cryptoUnits = configManager.getCryptoUnits(cryptoCode, settings.config)

    return {
      cryptoCode,
      cryptoCodeDisplay: cryptoRec.cryptoCodeDisplay ?? cryptoCode,
      display: cryptoRec.display,
      isCashInOnly: false,
      minimumTx: BN.max(minimumTx, cashInFee),
      cashInFee,
      cashOutFee,
      cashInCommission,
      cashOutCommission,
      cryptoNetwork,
      cryptoUnits
    }
  }

  function getTickerRates (fiatCode, cryptoCode) {
    return ticker.getRates(settings, fiatCode, cryptoCode)
  }

  function pollQueries () {
    const localeConfig = configManager.getLocale(deviceId, settings.config)
    const fiatCode = localeConfig.fiatCurrency
    const cryptoCodes = localeConfig.cryptoCurrencies
    const machineScreenOpts = configManager.getAllMachineScreenOpts(settings.config)

    const tickerPromises = cryptoCodes.map(c => getTickerRates(fiatCode, c))
    const balancePromises = cryptoCodes.map(c => fiatBalance(fiatCode, c))
    const networkPromises = cryptoCodes.map(c => wallet.cryptoNetwork(settings, c))
    const supportsBatchingPromise = cryptoCodes.map(c => wallet.supportsBatching(settings, c))

    return Promise.all([
      buildAvailableCassettes(),
      buildAvailableRecyclers(),
      settingsLoader.fetchCurrentConfigVersion(),
      millisecondsToMinutes(getTimezoneOffset(localeConfig.timezone)),
      loyalty.getNumberOfAvailablePromoCodes(),
      Promise.all(supportsBatchingPromise),
      Promise.all(tickerPromises),
      Promise.all(balancePromises),
      Promise.all(networkPromises)
    ])
      .then(([
        cassettes,
        recyclers,
        configVersion,
        timezone,
        numberOfAvailablePromoCodes,
        batchableCoins,
        tickers,
        balances,
        networks
      ]) => {
        const coinsWithoutRate = _.flow(
          _.zip(cryptoCodes),
          _.map(mapCoinSettings)
        )(networks)

        const coins = _.flow(
          _.map(it => ({ batchable: it })),
          _.zipWith(
            _.assign,
            _.zipWith(_.assign, coinsWithoutRate, tickers)
          )
        )(batchableCoins)

        return {
          cassettes,
          recyclers: recyclers,
          rates: buildRates(tickers),
          balances: buildBalances(balances),
          coins,
          configVersion,
          areThereAvailablePromoCodes: numberOfAvailablePromoCodes > 0,
          timezone,
          screenOptions: machineScreenOpts
        }
      })
  }

  function sendCoins (tx) {
    return wallet.supportsBatching(settings, tx.cryptoCode)
      .then(supportsBatching => {
        if (supportsBatching) {
          return transactionBatching.addTransactionToBatch(tx)
            .then(() => ({
              batched: true,
              sendPending: false,
              error: null,
              errorCode: null
            }))
        }
        return wallet.sendCoins(settings, tx)
      })
  }

  function recordPing (deviceTime, version, model) {
    const devices = {
      version,
      model,
      last_online: deviceTime
    }

    return Promise.all([
      db.none(`insert into machine_pings(device_id, device_time) values($1, $2) 
            ON CONFLICT (device_id) DO UPDATE SET device_time = $2, updated = now()`, [deviceId, deviceTime]),
      db.none(pgp.helpers.update(devices, null, 'devices') + 'WHERE device_id = ${deviceId}', {
        deviceId
      })
    ])
  }

  function pruneMachinesHeartbeat () {
    const sql = `DELETE FROM machine_network_heartbeat h
        USING (SELECT device_id, max(created) as lastEntry FROM machine_network_heartbeat GROUP BY device_id) d
        WHERE d.device_id = h.device_id AND h.created < d.lastEntry`
    db.none(sql)
  }

  function isHd (tx) {
    return wallet.isHd(settings, tx)
  }

  function getStatus (tx) {
    return wallet.getStatus(settings, tx, deviceId)
  }

  function newAddress (tx) {
    const info = {
      cryptoCode: tx.cryptoCode,
      label: 'TX ' + Date.now(),
      account: 'deposit',
      hdIndex: tx.hdIndex,
      cryptoAtoms: tx.cryptoAtoms,
      isLightning: tx.isLightning
    }
    return wallet.newAddress(settings, info, tx)
  }

  function fiatBalance (fiatCode, cryptoCode) {
    const commissions = configManager.getCommissions(cryptoCode, deviceId, settings.config)
    return Promise.all([
      getTickerRates(fiatCode, cryptoCode),
      wallet.balance(settings, cryptoCode)
    ])
      .then(([rates, balanceRec]) => {
        if (!rates || !balanceRec) return null

        const rawRate = rates.rates.ask
        const cashInCommission = new BN(1).minus(new BN(commissions.cashIn).div(100))
        const balance = balanceRec.balance

        if (!rawRate || !balance) return null

        const rate = rawRate.div(cashInCommission)

        const lowBalanceMargin = new BN(0.95)

        const cryptoRec = coinUtils.getCryptoCurrency(cryptoCode)
        const unitScale = cryptoRec.unitScale
        const shiftedRate = rate.shiftedBy(-unitScale)
        const fiatTransferBalance = balance.times(shiftedRate).times(lowBalanceMargin)

        return {
          timestamp: balanceRec.timestamp,
          balance: fiatTransferBalance.integerValue(BN.ROUND_DOWN).toString()
        }
      })
  }

  function notifyConfirmation (tx) {
    logger.debug('notifyConfirmation')

    const phone = tx.phone

    const timestamp = `${(new Date()).toISOString().substring(11, 19)} UTC`
    return sms.getSms(CASH_OUT_DISPENSE_READY, phone, { timestamp })
      .then(smsObj => {
        const rec = {
          sms: smsObj
        }
    
        return sms.sendMessage(settings, rec)
          .then(() => {
            const sql = 'UPDATE cash_out_txs SET notified=$1 WHERE id=$2'
            const values = [true, tx.id]

            return db.none(sql, values)
          })
      })
  }

  function notifyOperator (tx, rec) {
    // notify operator about new transaction and add high volume txs to database
    return notifier.transactionNotify(tx, rec)
  }

  function clearOldLogs () {
    return logs.clearOldLogs()
      .catch(logger.error)
  }

  function pong () {
    return db.none(`UPDATE server_events SET created=now() WHERE event_type=$1;
       INSERT INTO server_events (event_type) SELECT $1
       WHERE NOT EXISTS (SELECT 1 FROM server_events WHERE event_type=$1);`, ['ping'])
      .catch(logger.error)
  }

  /*
   * Trader functions
   */

  function toMarketString (fiatCode, cryptoCode) {
    return [fiatCode, cryptoCode].join('-')
  }
  
  function fromMarketString (market) {
    const [fiatCode, cryptoCode] = market.split('-')
    return { fiatCode, cryptoCode }
  }

  function buy (rec, tx) {
    return buyAndSell(rec, true, tx)
  }

  function sell (rec) {
    return buyAndSell(rec, false)
  }

  function buyAndSell (rec, doBuy, tx) {
    const cryptoCode = rec.cryptoCode
    if (!exchange.active(settings, cryptoCode)) return

    return exchange.fetchExchange(settings, cryptoCode)
      .then(_exchange => {
        const fiatCode = _exchange.account.currencyMarket
        const cryptoAtoms = doBuy ? commissionMath.fiatToCrypto(tx, rec, deviceId, settings.config) : rec.cryptoAtoms.negated()

        const market = toMarketString(fiatCode, cryptoCode)

        const direction = doBuy ? 'cashIn' : 'cashOut'
        const internalTxId = tx ? tx.id : rec.id
        logger.debug('[%s] Pushing trade: %d', market, cryptoAtoms)
        if (!tradesQueues[market]) tradesQueues[market] = []
        tradesQueues[market].push({
          direction,
          internalTxId,
          fiatCode,
          cryptoAtoms,
          cryptoCode,
          timestamp: Date.now()
        })
      })
  }

  function consolidateTrades (cryptoCode, fiatCode) {
    const market = toMarketString(fiatCode, cryptoCode)

    const marketTradesQueues = tradesQueues[market]
    if (!marketTradesQueues || marketTradesQueues.length === 0) return null

    logger.debug('[%s] tradesQueues size: %d', market, marketTradesQueues.length)
    logger.debug('[%s] tradesQueues head: %j', market, marketTradesQueues[0])

    const t1 = Date.now()

    const filtered = marketTradesQueues
      .filter(tradeEntry => {
        return t1 - tradeEntry.timestamp < TRADE_TTL
      })

    const filteredCount = marketTradesQueues.length - filtered.length

    if (filteredCount > 0) {
      tradesQueues[market] = filtered
      logger.debug('[%s] expired %d trades', market, filteredCount)
    }

    if (filtered.length === 0) return null

    const partitionByDirection = _.partition(({ direction }) => direction === 'cashIn')
    const [cashInTxs, cashOutTxs] = _.compose(partitionByDirection, _.uniqBy('internalTxId'))(filtered)

    const cryptoAtoms = filtered
      .reduce((prev, current) => prev.plus(current.cryptoAtoms), new BN(0))

    const timestamp = filtered.map(r => r.timestamp).reduce((acc, r) => Math.max(acc, r), 0)

    const consolidatedTrade = {
      cashInTxs,
      cashOutTxs,
      fiatCode,
      cryptoAtoms,
      cryptoCode,
      timestamp
    }

    tradesQueues[market] = []

    logger.debug('[%s] consolidated: %j', market, consolidatedTrade)
    return consolidatedTrade
  }

  function executeTrades () {
    const pairs = _.map(fromMarketString)(_.keys(tradesQueues))
    pairs.forEach(({ fiatCode, cryptoCode }) => {
      try {
        executeTradesForMarket(settings, fiatCode, cryptoCode)
      } catch (err) {
        logger.error(err)
      }
    })

    // Poller expects a promise
    return Promise.resolve()
  }

  function executeTradesForMarket (settings, fiatCode, cryptoCode) {
    if (!exchange.active(settings, cryptoCode)) return

    const market = toMarketString(fiatCode, cryptoCode)
    const tradeEntry = consolidateTrades(cryptoCode, fiatCode)

    if (tradeEntry === null || tradeEntry.cryptoAtoms.eq(0)) return

    return executeTradeForType(tradeEntry)
      .catch(err => {
        tradesQueues[market].push(tradeEntry)
        if (err.name === 'orderTooSmall') return logger.debug(err.message)
        logger.error(err)
      })
  }

  function executeTradeForType (_tradeEntry) {
    const expand = te => _.assign(te, {
      cryptoAtoms: te.cryptoAtoms.abs(),
      type: te.cryptoAtoms.gte(0) ? 'buy' : 'sell'
    })

    const tradeEntry = expand(_tradeEntry)
    const execute = tradeEntry.type === 'buy' ? exchange.buy : exchange.sell

    return recordTrade(tradeEntry)
      .then(newEntry => {
        tradeEntry.tradeId = newEntry.id
        return execute(settings, tradeEntry)
          .catch(err => {
            updateTradeEntry(tradeEntry, newEntry, err)
              .then(() => {
                logger.error(err)
                throw err
              })
          })
      })
  }

  function updateTradeEntry (tradeEntry, newEntry, err) {
    const data = mergeTradeEntryAndError(tradeEntry, err)
    const sql = pgp.helpers.update(data, ['error'], 'trades') + ` WHERE id = ${newEntry.id}`
    return db.none(sql)
  }

  function recordTradeAndTx (tradeId, { cashInTxs, cashOutTxs }, dbTx) {
    const columnSetCashIn = new pgp.helpers.ColumnSet(['tx_id', 'trade_id'], { table: 'cashin_tx_trades' })
    const columnSetCashOut = new pgp.helpers.ColumnSet(['tx_id', 'trade_id'], { table: 'cashout_tx_trades' })
    const mapToEntry = _.map(tx => ({ tx_id: tx.internalTxId, trade_id: tradeId }))
    const queries = []

    if (!_.isEmpty(cashInTxs)) {
      const query = pgp.helpers.insert(mapToEntry(cashInTxs), columnSetCashIn)
      queries.push(dbTx.none(query))
    }
    if (!_.isEmpty(cashOutTxs)) {
      const query = pgp.helpers.insert(mapToEntry(cashOutTxs), columnSetCashOut)
      queries.push(dbTx.none(query))
    }
    return Promise.all(queries)
  }

  function convertBigNumFields (obj) {
    const convert = (value, key) => _.includes(key, ['cryptoAtoms', 'fiat'])
      ? value.toString()
      : value

    const convertKey = key => _.includes(key, ['cryptoAtoms', 'fiat'])
      ? key + '#'
      : key

    return _.mapKeys(convertKey, mapValuesWithKey(convert, obj))
  }

  function mergeTradeEntryAndError (tradeEntry, error) {
    if (error && error.message) {
      return Object.assign({}, tradeEntry, {
        error: error.message.slice(0, 200)
      })
    }
    return tradeEntry
  }

  function recordTrade (_tradeEntry, error) {
    const massage = _.flow(
      mergeTradeEntryAndError,
      _.pick(['cryptoCode', 'cryptoAtoms', 'fiatCode', 'type', 'error']),
      convertBigNumFields,
      _.mapKeys(_.snakeCase)
    )
    const tradeEntry = massage(_tradeEntry, error)
    const sql = pgp.helpers.insert(tradeEntry, null, 'trades') + 'RETURNING *'
    return db.tx(t => {
      return t.oneOrNone(sql)
        .then(newTrade => {
          return recordTradeAndTx(newTrade.id, _tradeEntry, t)
          .then(() => newTrade)
        })
    })
  }

  function sendMessage (rec) {
    const notifications = configManager.getGlobalNotifications(settings.config)

    let promises = []
    if (notifications.email.active && rec.email) promises.push(email.sendMessage(settings, rec))
    if (notifications.sms.active && rec.sms) promises.push(sms.sendMessage(settings, rec))

    return Promise.all(promises)
  }

  function checkDevicesCashBalances (fiatCode, devices) {
    return _.map(device => checkDeviceCashBalances(fiatCode, device), devices)
  }

  function getCashUnitCapacity (model, device) {
    if (!CASH_UNIT_CAPACITY[model]) {
      return CASH_UNIT_CAPACITY.default[device]
    }
    return CASH_UNIT_CAPACITY[model][device]
  }

  function checkDeviceCashBalances (fiatCode, device) {
    const deviceId = device.deviceId
    const machineName = device.name
    const notifications = configManager.getNotifications(null, deviceId, settings.config)

    const cashInAlerts = device.cashUnits.cashbox > notifications.cashInAlertThreshold
      ? [{
        code: 'CASH_BOX_FULL',
        machineName,
        deviceId,
        notes: device.cashUnits.cashbox
      }]
      : []

    const cashOutConfig = configManager.getCashOut(deviceId, settings.config)
    const cashOutEnabled = cashOutConfig.active
    const isUnitLow = (have, max, limit) => ((have / max) * 100) < limit

    if (!cashOutEnabled)
      return cashInAlerts

    const cassetteCapacity = getCashUnitCapacity(device.model, 'cassette')
    const cassetteAlerts = Array(Math.min(device.numberOfCassettes ?? 0, CASH_OUT_MAXIMUM_AMOUNT_OF_CASSETTES))
      .fill(null)
      .flatMap((_elem, idx) => {
        const nth = idx + 1
        const cassetteField = `cassette${nth}`
        const notes = device.cashUnits[cassetteField]
        const denomination = cashOutConfig[cassetteField]

        const limit = notifications[`fillingPercentageCassette${nth}`]
        return isUnitLow(notes, cassetteCapacity, limit) ?
          [{
            code: 'LOW_CASH_OUT',
            cassette: nth,
            machineName,
            deviceId,
            notes,
            denomination,
            fiatCode
          }] :
          []
      })

    const recyclerCapacity = getCashUnitCapacity(device.model, 'recycler')
    const recyclerAlerts = Array(Math.min(device.numberOfRecyclers ?? 0, CASH_OUT_MAXIMUM_AMOUNT_OF_RECYCLERS))
      .fill(null)
      .flatMap((_elem, idx) => {
        const nth = idx + 1
        const recyclerField = `recycler${nth}`
        const notes = device.cashUnits[recyclerField]
        const denomination = cashOutConfig[recyclerField]

        const limit = notifications[`fillingPercentageRecycler${nth}`]
        return isUnitLow(notes, recyclerCapacity, limit) ?
          [{
            code: 'LOW_RECYCLER_STACKER',
            cassette: nth, // @see DETAIL_TEMPLATE in /lib/notifier/utils.js
            machineName,
            deviceId,
            notes,
            denomination,
            fiatCode
          }] :
          []
      })

    return [].concat(cashInAlerts, cassetteAlerts, recyclerAlerts)
  }

  function checkCryptoBalances (fiatCode, devices) {
    const fiatBalancePromises = cryptoCodes => _.map(c => fiatBalance(fiatCode, c), cryptoCodes)

    const fetchCryptoCodes = _deviceId => {
      const localeConfig = configManager.getLocale(_deviceId, settings.config)
      return localeConfig.cryptoCurrencies
    }

    const union = _.flow(_.map(fetchCryptoCodes), _.flatten, _.uniq)
    const cryptoCodes = union(devices)
    const checkCryptoBalanceWithFiat = _.partial(checkCryptoBalance, [fiatCode])

    return Promise.all(fiatBalancePromises(cryptoCodes))
      .then(balances => _.map(checkCryptoBalanceWithFiat, _.zip(cryptoCodes, balances)))
  }

  function checkCryptoBalance (fiatCode, rec) {
    const [cryptoCode, fiatBalance] = rec
    if (!fiatBalance) return null

    const notifications = configManager.getNotifications(cryptoCode, null, settings.config)
    const lowAlertThreshold = notifications.cryptoLowBalance
    const highAlertThreshold = notifications.cryptoHighBalance

    const req = {
      cryptoCode,
      fiatBalance,
      fiatCode
    }

    if (_.isFinite(lowAlertThreshold) && new BN(fiatBalance.balance).lt(lowAlertThreshold)) {
      return _.set('code')('LOW_CRYPTO_BALANCE')(req)
    }

    if (_.isFinite(highAlertThreshold) && new BN(fiatBalance.balance).gt(highAlertThreshold)) {
      return _.set('code')('HIGH_CRYPTO_BALANCE')(req)
    }

    return null
  }

  function checkBalances () {
    const localeConfig = configManager.getGlobalLocale(settings.config)
    const fiatCode = localeConfig.fiatCurrency

    return machineLoader.getMachines()
      .then(devices => Promise.all([
        checkCryptoBalances(fiatCode, devices),
        checkDevicesCashBalances(fiatCode, devices)
      ]))
      .then(_.flow(_.flattenDeep, _.compact))
  }

  function randomCode () {
    return new BN(crypto.randomBytes(3).toString('hex'), 16).shiftedBy(-6).toFixed(6).slice(-6)
  }

  function getPhoneCode (phone) {
    const code = settings.config.notifications_thirdParty_sms === 'mock-sms'
      ? '123'
      : randomCode()

    const timestamp = `${(new Date()).toISOString().substring(11, 19)} UTC`
    return sms.getSms(CONFIRMATION_CODE, phone, { code, timestamp })
      .then(smsObj => {
        const rec = {
          sms: smsObj
        }

        return sms.sendMessage(settings, rec)
          .then(() => code)
      })
  }

  function getEmailCode (toEmail) {
    const code = settings.config.notifications_thirdParty_email === 'mock-email'
      ? '123'
      : randomCode()

    const rec = {
      email: {
        toEmail,
        subject: 'Your cryptomat code',
        body: `Your cryptomat code: ${code}`
      }
    }

    return email.sendCustomerMessage(settings, rec)
      .then(() => code)
  }

  function sweepHdRow (row) {
    const txId = row.id
    const cryptoCode = row.crypto_code

    return wallet.sweep(settings, txId, cryptoCode, row.hd_index)
      .then(txHash => {
        if (txHash) {
          logger.debug('[%s] Swept address with tx: %s', cryptoCode, txHash)

          const sql = `update cash_out_txs set swept='t'
      where id=$1`

          return db.none(sql, row.id)
        }
      })
      .catch(err => logger.error('[%s] [Session ID: %s] Sweep error: %s', cryptoCode, row.id, err.message))
  }

  function sweepHd () {
    const sql = `SELECT id, crypto_code, hd_index FROM cash_out_txs
  WHERE hd_index IS NOT NULL AND NOT swept AND status IN ('confirmed', 'instant') AND created > now() - interval '1 week'`

    return db.any(sql)
      .then(rows => Promise.all(rows.map(sweepHdRow)))
      .catch(logger.error)
  }

  function getMachineNames () {
    return machineLoader.getMachineNames(settings.config)
  }

  function getRawRates () {
    const localeConfig = configManager.getGlobalLocale(settings.config)
    const fiatCode = localeConfig.fiatCurrency

    const cryptoCodes = configManager.getAllCryptoCurrencies(settings.config)
    const tickerPromises = cryptoCodes.map(c => getTickerRates(fiatCode, c))

    return Promise.all(tickerPromises)
  }

  function getRates () {
    return getRawRates()
      .then(buildRates)
  }

  function rateAddress (cryptoCode, address) {
    return walletScoring.rateAddress(settings, cryptoCode, address)
  }

  function rateTransaction (cryptoCode, address) {
    return walletScoring.rateTransaction(settings, cryptoCode, address)
  }

  function isWalletScoringEnabled (tx) {
    return walletScoring.isWalletScoringEnabled(settings, tx.cryptoCode)
  }

  function probeLN (cryptoCode, address) {
    return wallet.probeLN(settings, cryptoCode, address)
  }

  return {
    getRates,
    recordPing,
    buildRates,
    getRawRates,
    buildRatesNoCommission,
    pollQueries,
    sendCoins,
    newAddress,
    isHd,
    isZeroConf,
    getStatus,
    getPhoneCode,
    getEmailCode,
    executeTrades,
    pong,
    clearOldLogs,
    notifyConfirmation,
    sweepHd,
    sendMessage,
    checkBalances,
    getMachineNames,
    buy,
    sell,
    getNotificationConfig,
    notifyOperator,
    pruneMachinesHeartbeat,
    rateAddress,
    rateTransaction,
    isWalletScoringEnabled,
    probeLN,
    buildAvailableUnits
  }
}

module.exports = plugins
