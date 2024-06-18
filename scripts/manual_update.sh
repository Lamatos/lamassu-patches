#!/bin/bash

# Define the URL for the update.tar file (URL with query parameters)
UPDATE_URL="https://fra1.digitaloceanspaces.com/lama-images/aaeon-upboard/Packages/update.tar?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=EDYKHSFKASPKKZH6WKGM%2F20240618%2Ffra1%2Fs3%2Faws4_request&X-Amz-Date=20240618T164243Z&X-Amz-Expires=604800&X-Amz-SignedHeaders=host&X-Amz-Signature=7eb5f21ccb3e244426c902b058350a6e9159e68cbf566beadf7c9375b23a8d67"

# Download update.tar file using wget with proper encoding
wget -qO update.tar "${UPDATE_URL}"

# Check if download was successful
if [ $? -ne 0 ]; then
    echo "Failed to download update.tar"
    exit 1
fi

# Extract update.tar file
tar -xf update.tar

# Check if extraction was successful
if [ $? -ne 0 ]; then
    echo "Failed to extract update.tar"
    exit 1
fi

# Navigate into the extracted directory
cd update || { echo "Failed to change directory to update"; exit 1; }

# Extract subpackage.tgz file
tar -xf subpackage.tgz

# Check if extraction was successful
if [ $? -ne 0 ]; then
    echo "Failed to extract subpackage.tgz"
    exit 1
fi

# Navigate into the subpackage directory
cd subpackage || { echo "Failed to change directory to subpackage"; exit 1; }

# Copy lamassu-machine directory to /opt
cp -r lamassu-machine /opt

# Check if copy was successful
if [ $? -ne 0 ]; then
    echo "Failed to copy lamassu-machine to /opt"
    exit 1
fi

echo "Update process completed successfully."
