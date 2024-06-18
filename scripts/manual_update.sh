#!/bin/bash

# Define the URL for the update.tar file (URL with query parameters)
UPDATE_URL="https://fra1.digitaloceanspaces.com/lama-images/aaeon-upboard/Packages/update.tar?SIGNED-QUERY-REMOVED"

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

# List contents of current directory for debugging
ls -la

# Navigate into the extracted update directory
cd update || { echo "Failed to change directory to update"; ls -la; exit 1; }

# List contents of update directory for debugging
ls -la

# Extract subpackage.tgz file
tar -xf subpackage.tgz

# Check if extraction was successful
if [ $? -ne 0 ]; then
    echo "Failed to extract subpackage.tgz"
    exit 1
fi

# List contents of current directory for debugging
ls -la

# Navigate into the subpackage directory
cd subpackage || { echo "Failed to change directory to subpackage"; ls -la; exit 1; }

# List contents of subpackage directory for debugging
ls -la

# Copy lamassu-machine directory to /opt
cp -r lamassu-machine /opt

# Check if copy was successful
if [ $? -ne 0 ]; then
    echo "Failed to copy lamassu-machine to /opt"
    exit 1
fi

echo "Update process completed successfully."
