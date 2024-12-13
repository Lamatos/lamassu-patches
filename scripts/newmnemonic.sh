#!/usr/bin/env bash

# Exit immediately if any command exits with a non-zero status
set -e

# Define variables
CONFIG_DIR="/etc/lamassu"
MNEMONIC_DIR="$CONFIG_DIR/mnemonics"
MNEMONIC_FILE="$MNEMONIC_DIR/mnemonic.txt"
BACKUP_FILE="$MNEMONIC_FILE.bak"

# Function to print messages with a timestamp
log_message() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Start script execution
log_message "Starting the wallet seed generation script."

# Generate a new seed and mnemonic
log_message "Generating a new wallet seed and mnemonic."
SEED=$(openssl rand -hex 32)
MNEMONIC=$(bip39 $SEED)

if [ -z "$MNEMONIC" ]; then
    log_message "Error: Failed to generate mnemonic. Exiting."
    exit 1
fi

# Ensure the mnemonic directory exists
log_message "Ensuring mnemonic directory exists at $MNEMONIC_DIR."
mkdir -p "$MNEMONIC_DIR"

# Backup the existing mnemonic file if it exists
if [ -f "$MNEMONIC_FILE" ]; then
    log_message "Backing up existing mnemonic file to $BACKUP_FILE."
    mv "$MNEMONIC_FILE" "$BACKUP_FILE"
else
    log_message "No existing mnemonic file found. Skipping backup."
fi

# Save the new mnemonic to the file
log_message "Saving the new mnemonic to $MNEMONIC_FILE."
echo "$MNEMONIC" > "$MNEMONIC_FILE"

# Restart the Lamassu services
log_message "Restarting Lamassu services."
supervisorctl restart lamassu-server lamassu-admin-server

if [ $? -eq 0 ]; then
    log_message "Services restarted successfully."
else
    log_message "Error: Failed to restart services. Check Supervisor logs for details."
    exit 1
fi

log_message "Script completed successfully. New mnemonic saved and services restarted."
