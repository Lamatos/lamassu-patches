#!/bin/bash
set -e

export LOG_FILE=/tmp/monero-update.$(date +"%Y%m%d").log

echo
echo "Updating your Monero wallet. This may take a minute."
echo

echo "Downloading Monero v0.18.2.2..."
sourceHash=$'186800de18f67cca8475ce392168aabeb5709a8f8058b0f7919d7c693786d56b'
curl -#Lo /tmp/monero.tar.bz2 https://downloads.getmonero.org/cli/monero-linux-x64-v0.18.2.2.tar.bz2 >> ${LOG_FILE} 2>&1
hash=$(sha256sum /tmp/monero.tar.bz2 | awk '{print $1}' | sed 's/ *$//g')

if [ $hash != $sourceHash ] ; then
        echo 'Package signature do not match!'
        exit 1
fi

supervisorctl stop monero monero-wallet >> ${LOG_FILE} 2>&1
tar -xf /tmp/monero.tar.bz2 -C /tmp/ >> ${LOG_FILE} 2>&1
echo

echo "Updating wallet..."
cp /tmp/monero-x86_64-linux-gnu-v0.18.2.2/monerod /usr/local/bin/ >> ${LOG_FILE} 2>&1
cp /tmp/monero-x86_64-linux-gnu-v0.18.2.2/monero-wallet-rpc /usr/local/bin/ >> ${LOG_FILE} 2>&1
rm -r /tmp/monero-x86_64-linux-gnu-v0.18.2.2 >> ${LOG_FILE} 2>&1
rm /tmp/monero.tar.bz2 >> ${LOG_FILE} 2>&1
echo

echo "Starting wallet..."
supervisorctl start monero monero-wallet >> ${LOG_FILE} 2>&1
echo

echo "Monero is updated."
echo
