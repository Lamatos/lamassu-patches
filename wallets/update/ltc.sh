#!/bin/bash
set -e

export LOG_FILE=/tmp/ltc-update.$(date +"%Y%m%d").log

echo
echo "Updating Litecoin Core. This may take a minute."
echo

echo "Downloading v0.21.2.1..."
sourceHash=$'6e545d1ef0842b9c4ecaf2e22b43f17fd3fba73599b0d6cc1db0c9310f1a74ff'
curl -#o /tmp/litecoin.tar.gz https://download.litecoin.org/litecoin-0.21.2.1/linux/litecoin-0.21.2.1-x86_64-linux-gnu.tar.gz >> ${LOG_FILE} 2>&1
hash=$(sha256sum /tmp/litecoin.tar.gz | awk '{print $1}' | sed 's/ *$//g')

if [ $hash != $sourceHash ] ; then
        echo 'Package signature do not match!'
        exit 1
fi
tar -xzf /tmp/litecoin.tar.gz -C /tmp/ >> ${LOG_FILE} 2>&1
echo

supervisorctl stop litecoin >> ${LOG_FILE} 2>&1

echo "Updating wallet..."
cp /tmp/litecoin-0.21.2.1/bin/* /usr/local/bin/ >> ${LOG_FILE} 2>&1
rm -r /tmp/litecoin-0.21.2.1 >> ${LOG_FILE} 2>&1
rm /tmp/litecoin.tar.gz >> ${LOG_FILE} 2>&1
echo

if grep -q "changetype=" /mnt/blockchains/litecoin/litecoin.conf
then
    echo "changetype already defined, skipping..."
else
    echo "Enabling bech32 change addresses in config file..."
    echo -e "\nchangetype=bech32" >> /mnt/blockchains/litecoin/litecoin.conf
fi
echo

echo "Starting wallet..."
supervisorctl start litecoin >> ${LOG_FILE} 2>&1
echo

echo "Litecoin Core is updated."
echo
