#!/bin/bash

# Set the URL for the update.tar file
UPDATE_URL="https://fra1.digitaloceanspaces.com/lama-images/aaeon-upboard/Packages/update.tar?SIGNED-QUERY-REMOVED"

# Download the update.tar file using wget
wget -q "$UPDATE_URL" -O update.tar

# Check if the download was successful
if [ $? -ne 0 ]; then
    echo "Failed to download update.tar"
    exit 1
fi

# Extract the update.tar file
tar -xf update.tar

# Check if the extraction was successful
if [ $? -ne 0 ]; then
    echo "Failed to extract update.tar"
    exit 1
fi

# Change directory to the extracted update directory
cd update || { echo "Failed to change directory to update"; exit 1; }

# Extract the subpackage.tgz file
tar -xf subpackage.tgz

# Check if the extraction was successful
if [ $? -ne 0 ]; then
    echo "Failed to extract subpackage.tgz"
    exit 1
fi

# Change directory to the subpackage directory
cd subpackage || { echo "Failed to change directory to subpackage"; exit 1; }

# Copy the lamassu-machine directory to /opt
cp -r lamassu-machine /opt

# Check if the copy was successful
if [ $? -ne 0 ]; then
    echo "Failed to copy lamassu-machine to /opt"
    exit 1
fi

echo "Update process completed successfully."
