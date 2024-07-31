#!/bin/bash

# Prompt the user to enter BTC addresses
echo "Enter BTC addresses to blacklist. Type 'done' when finished."

addresses=()
while true; do
    read -p "Enter a BTC address: " address
    if [[ "$address" == "done" ]]; then
        break
    fi
    addresses+=("$address")
done

# Check if there are any addresses to add
if [ ${#addresses[@]} -eq 0 ]; then
    echo "No addresses to add."
    exit 0
fi

# Insert addresses into the blacklist table
echo "Adding addresses to the blacklist..."

for address in "${addresses[@]}"; do
    psql lamassu -c \
        "INSERT INTO blacklist (crypto_code, address) VALUES ('BTC', '$address');"
done

echo "Addresses successfully added to the blacklist."
