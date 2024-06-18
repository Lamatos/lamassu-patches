#!/bin/bash

# Set the URL for the update.tar file
UPDATE_URL="https://fra1.digitaloceanspaces.com/lama-images/aaeon-upboard/Packages/update.tar?SIGNED-QUERY-REMOVED"

# Download the update.tar file
curl -O $UPDATE_URL

# Extract the update.tar file
tar -xf update.tar

# Change directory to the extracted update directory
cd update

# Extract the subpackage.tgz file
tar -xf subpackage.tgz

# Change directory to the subpackage directory
cd subpackage

# Copy the lamassu-machine directory to /opt
cp -r lamassu-machine /opt

echo "Update process completed successfully."
