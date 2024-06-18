#!/bin/bash

# Define the URL for the update.tar file (URL with query parameters)
UPDATE_URL="https://fra1.digitaloceanspaces.com/lama-images/aaeon-upboard/Packages/update.tar?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=EDYKHSFKASPKKZH6WKGM%2F20240618%2Ffra1%2Fs3%2Faws4_request&X-Amz-Date=20240618T164243Z&X-Amz-Expires=604800&X-Amz-SignedHeaders=host&X-Amz-Signature=7eb5f21ccb3e244426c902b058350a6e9159e68cbf566beadf7c9375b23a8d67"

# Function to display a progress bar
# Usage: progress_bar <current_progress> <total_progress>
progress_bar() {
    local current_progress=$1
    local total_progress=$2
    local percentage=$((current_progress * 100 / total_progress))
    local completed=$((percentage / 2))
    local remaining=$((50 - completed))
    printf "\r[%-${completed}s%-${remaining}s] %d%%" "==" " " "$percentage"
}

# Download update.tar file
echo "Downloading update.tar..."
wget --progress=bar:force:noscroll -qO update.tar "$UPDATE_URL"

# Check if download was successful
if [ $? -ne 0 ]; then
    echo "Failed to download update.tar"
    exit 1
fi

echo -e "\nDownload complete."

# Extract update.tar file
echo "Extracting update.tar..."
tar -xf update.tar -C /tmp || {
    echo "Failed to extract update.tar"
    exit 1
}

echo "Extraction complete."

# Navigate into the extracted package directory
cd /tmp/package || {
    echo "Failed to change directory to /tmp/package"
    ls -la /tmp
    exit 1
}

# List contents of package directory for debugging
ls -la

# Extract subpackage.tgz file
echo "Extracting subpackage.tgz..."
tar -xf subpackage.tgz || {
    echo "Failed to extract subpackage.tgz"
    exit 1
}

echo "Extraction complete."

# Navigate into the subpackage directory
cd subpackage || {
    echo "Failed to change directory to subpackage"
    ls -la /tmp/package
    exit 1
}

# List contents of subpackage directory for debugging
ls -la

# Copy lamassu-machine directory to /opt
echo "Copying lamassu-machine to /opt..."
cp -r lamassu-machine /opt || {
    echo "Failed to copy lamassu-machine to /opt"
    exit 1
}

echo "Copy complete."

echo "Update process completed successfully."
