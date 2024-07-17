#!/bin/bash

# Define the URL of the file and the destination path
FILE_URL="https://raw.githubusercontent.com/lamassu/lamassu-machine/1bf37b157f73fa1facfdaed4e22995783ff71479/hardware/system/coincloud/jcm-ipro-rc/udev/99-jcm-ipro-rc.rules"
DEST_PATH="/etc/udev/rules.d/99-jcm-ipro-rc.rules"

# Download the file and place it in the destination path
curl -o "$DEST_PATH" -L "$FILE_URL"

# Reload the udev rules
udevadm control --reload-rules
udevadm trigger

# Print done message
echo "Done!"
