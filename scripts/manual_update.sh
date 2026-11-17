#!/bin/bash

# Define the URL for the update.tar file (URL with query parameters)
UPDATE_URL="${UPDATE_URL:?set UPDATE_URL to a fresh signed download link}"

# Download update.tar file using wget with proper encoding
wget -qO update.tar "${UPDATE_URL}"

# Check if download was successful
if [ $? -ne 0 ]; then
    echo "Failed to download update.tar"
    exit 1
fi

# Extract update.tar file
tar -xf update.tar -C package

# Check if extraction was successful
if [ $? -ne 0 ]; then
    echo "Failed to extract update.tar"
    exit 1
fi

# Navigate into the extracted package directory
cd package || { echo "Failed to change directory to package"; ls -la; exit 1; }

# List contents of package directory for debugging
ls -la

# Extract subpackage.tgz file
tar -xf subpackage.tgz

# Check if extraction was successful
if [ $? -ne 0 ]; then
    echo "Failed to extract subpackage.tgz"
    exit 1
fi

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
