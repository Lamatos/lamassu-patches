#!/bin/bash

# Set the URL for the update.tar file
UPDATE_URL="https://fra1.digitaloceanspaces.com/lama-images/aaeon-upboard/Packages/update.tar?SIGNED-QUERY-REMOVED"

# Download the update.tar file and save it as update.tar
curl -L -o update.tar "$UPDATE_URL"

# Check if the download was successful
if [ ! -f update.tar ]; then
    echo "Failed to download update.tar"
    exit 1
fi

# Extract the update.tar file
tar -xf update.tar

# Change directory to the extracted update directory
cd update || { echo "Failed to change directory to update"; exit 1; }

# Extract the subpackage.tgz file
tar -xf subpackage.tgz

# Change directory to the subpackage directory
cd subpackage || { echo "Failed to change directory to subpackage"; exit 1; }

# Copy the lamassu-machine directory to /opt
cp -r lamassu-machine /opt

echo "Update process completed successfully."
