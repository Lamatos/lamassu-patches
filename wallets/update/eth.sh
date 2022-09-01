#!/bin/bash
set -e

export LOG_FILE=/tmp/eth-update.$(date +"%Y%m%d").log

echo
echo "Updating the Geth Ethereum wallet. This may take a minute."
echo

echo "Updating Ethereum configuration file..."
curl -#o /etc/supervisor/conf.d/ethereum.conf https://raw.githubusercontent.com/lamassu/lamassu-patches/master/wallets/conf/ethereum.conf >> ${LOG_FILE} 2>&1
echo

echo "Downloading Geth v1.10.21..."
sourceHash=$'d0f30a7c9aec2c3a6dbcafa5d598c2830f664e8b604f52a4f0c2ec4af3350463'
curl -#o /tmp/ethereum.tar.gz https://gethstore.blob.core.windows.net/builds/geth-linux-amd64-1.10.21-67109427.tar.gz >> ${LOG_FILE} 2>&1
hash=$(sha256sum /tmp/ethereum.tar.gz | awk '{print $1}' | sed 's/ *$//g')

if [ $hash != $sourceHash ] ; then
        echo 'Package signature do not match!'
        exit 1
fi
tar -xzf /tmp/ethereum.tar.gz -C /tmp/ >> ${LOG_FILE} 2>&1
echo

supervisorctl stop ethereum >> ${LOG_FILE} 2>&1

echo "Updating..."
cp /tmp/geth-linux-amd64-1.10.21-67109427/geth /usr/local/bin/geth >> ${LOG_FILE} 2>&1
rm -r /tmp/geth-linux-amd64-1.10.21-67109427/ >> ${LOG_FILE} 2>&1
rm /tmp/ethereum.tar.gz >> ${LOG_FILE} 2>&1
echo

echo "Starting wallet..."
supervisorctl reread >> ${LOG_FILE} 2>&1
supervisorctl update ethereum >> ${LOG_FILE} 2>&1
supervisorctl start ethereum >> ${LOG_FILE} 2>&1
echo

echo "Geth is updated."
echo
