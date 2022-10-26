#!/usr/bin/env bash

echo
echo "Patching lamassu-eth-recovery..."

cd /bin && rm -rf lamassu-eth-recovery
curl -#o $(npm root -g)/lamassu-server/bin/lamassu-eth-recovery https://raw.githubusercontent.com/josepfo/lamassu-server/104899c0ac6323cc8e0e6a39c7a88107a3cfb3e8/bin/lamassu-eth-recovery

echo
echo "Done. Please inform support that this script has been run."
echo
