#!/bin/bash

# Define the URL for the update.tar file (URL with query parameters)
UPDATE_URL="https://fra1.digitaloceanspaces.com/lama-images/aaeon-upboard/Packages/update.tar?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=EDYKHSFKASPKKZH6WKGM%2F20240618%2Ffra1%2Fs3%2Faws4_request&X-Amz-Date=20240618T164243Z&X-Amz-Expires=604800&X-Amz-SignedHeaders=host&X-Amz-Signature=7eb5f21ccb3e244426c902b058350a6e9159e68cbf566beadf7c9375b23a8d67"

# Function to display a progress bar during download
progress_bar() {
    local downloaded_size=$1
    local total_size=$2
    local percentage=0
    if [ $total_size -gt 0 ]; then
        percentage=$((downloaded_size * 100 / total_size))
    fi
    local progress=$((percentage / 2))
    local dots=$((50 - progress))
    printf "\r[%-${progress}s%-${dots}s] %d%%" "==" " " "$percentage"
}

# Download update.tar file and show progress
echo "Downloading v9.0.0 update package..."
wget --progress=bar:force:noscroll --show-progress -O update.tar "$UPDATE_URL" 2>&1 | {
    while IFS= read -r line; do
        if [[ $line =~ ([0-9.]+)%\s+in\s+([0-9.]+[KM]?)s ]]; then
            progress_bar "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        fi
    done
}

# Check if download was successful
if [ $? -ne 0 ]; then
    echo -e "\nFailed to download update package"
    exit 1
fi

echo -e "\nDownload complete."

# Extract update.tar file
echo "Extracting update package..."
tar -xf update.tar -C /tmp || {
    echo "Failed to extract update package"
    exit 1
}

echo "Extraction complete."

# Navigate into the extracted package directory (assuming it extracts to 'package')
cd /tmp/package || {
    echo "Failed to change directory to /tmp/package"
    ls -la /tmp > /dev/null
    exit 1
}

# List contents of package directory for debugging (redirect output to /dev/null)
ls -la /tmp/package > /dev/null

# Extract subpackage.tgz file (assuming it extracts to 'subpackage')
echo "Extracting subpackages..."
tar -xf subpackage.tgz || {
    echo "Failed to extract subpackage"
    exit 1
}

echo "Extraction complete."

# Navigate into the subpackage directory
cd subpackage || {
    echo "Failed to change directory to subpackage"
    ls -la /tmp/package > /dev/null
    exit 1
}

# List contents of subpackage directory for debugging (redirect output to /dev/null)
ls -la /tmp/package/subpackage > /dev/null

# Copy lamassu-machine directory to /opt
echo "Updating lamassu-machine..."
cp -r lamassu-machine /opt || {
    echo "Update failed when copying files. Please reach out to our support team!"
    exit 1
}

echo "Done"

echo "Update process completed successfully!"
