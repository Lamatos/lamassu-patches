#!/bin/bash

# Define the URL for the update.tar file (URL with query parameters)
UPDATE_URL="https://fra1.digitaloceanspaces.com/lama-images/aaeon-upboard/Packages/update.tar?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=EDYKHSFKASPKKZH6WKGM%2F20240618%2Ffra1%2Fs3%2Faws4_request&X-Amz-Date=20240618T164243Z&X-Amz-Expires=604800&X-Amz-SignedHeaders=host&X-Amz-Signature=7eb5f21ccb3e244426c902b058350a6e9159e68cbf566beadf7c9375b23a8d67"

# Function to display progress bar during download
progress_bar() {
    local file_size=$(curl -sI "${UPDATE_URL}" | grep -i Content-Length | awk '{print $2}')
    local total_size=$((file_size / 1024))  # Convert bytes to kilobytes
    local downloaded_size=0
    local progress=0
    local bar_width=50

    # Download update.tar file with progress indicator
    curl -s "${UPDATE_URL}" | {
        # Use dd to count bytes as they are transferred
        while IFS= read -r -n 1024 chunk; do
            echo -n "$chunk"
            downloaded_size=$((downloaded_size + 1))
            progress=$((downloaded_size * 100 / total_size))

            # Print the progress bar
            printf "["
            local completed=$((progress * bar_width / 100))
            for ((i = 0; i < completed; i++)); do
                printf "="
            done
            printf ">%2d%%]\r" "$progress"
        done
        echo ""
    } | tar -xf - -C package
}

# Call the progress_bar function to download and extract update.tar
progress_bar

# Check if download and extraction were successful
if [ $? -ne 0 ]; then
    echo "Failed to download and extract update.tar"
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
