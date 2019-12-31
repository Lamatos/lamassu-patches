#!/bin/bash
set -e

export LOG_FILE=/tmp/btc-update.$(date +"%Y%m%d").log

echo
echo "Updating Bitcoin Core. This may take a minute."
supervisorctl stop bitcoin >> ${LOG_FILE} 2>&1
echo
echo "Downloading..."
curl -#o $(npm root -g)/lamassu-server/lib/plugins/wallet/bitcoind/bitcoind.js https://raw.githubusercontent.com/lamassu/lamassu-server/defiant-dingirma/lib/plugins/wallet/bitcoind/bitcoind.js
curl -#o /tmp/bitcoin.tar.gz https://bitcoin.org/bin/bitcoin-core-0.19.0.1/bitcoin-0.19.0.1-x86_64-linux-gnu.tar.gz >> ${LOG_FILE} 2>&1
tar -xzf /tmp/bitcoin.tar.gz -C /tmp/ >> ${LOG_FILE} 2>&1
echo
echo "Updating..."
mv /usr/local/bin/bitcoind /usr/local/bin/bitcoind-old >> ${LOG_FILE} 2>&1
mv /usr/local/bin/bitcoin-cli /usr/local/bin/bitcoin-cli-old >> ${LOG_FILE} 2>&1
mv /usr/local/bin/bitcoin-tx /usr/local/bin/bitcoind-tx-old >> ${LOG_FILE} 2>&1
mv /usr/local/bin/bitcoin-qt /usr/local/bin/bitcoind-qt-old >> ${LOG_FILE} 2>&1
cp /tmp/bitcoin-0.19.0.1/bin/* /usr/local/bin/ >> ${LOG_FILE} 2>&1
rm -r /tmp/bitcoin-0.19.0.1 >> ${LOG_FILE} 2>&1
rm /tmp/bitcoin.tar.gz >> ${LOG_FILE} 2>&1
supervisorctl start bitcoin >> ${LOG_FILE} 2>&1
supervisorctl restart lamassu-server lamassu-admin-server >> ${LOG_FILE} 2>&1
echo
echo "Bitcoin Core is updated."
echo
