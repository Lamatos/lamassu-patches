#!/bin/bash

echo "Limpinho limping....."

# 1. Clear terminal history
echo > ~/.bash_history
history -c

# 2. Wipe Supervisor logs
echo "Limpinho limped logs"
rm -f /var/log/supervisor/*.log

# 3. Go to /opt/lamassu-machine/data
cd /opt/lamassu-machine/data || { echo "lamassu-machine/data folder not found!"; exit 1; }

# 4. Remove specified files and folders
echo "Limpinho unpaired and limped /data"
rm -f client.key
rm -f client.pem
rm -rf tx-db
rm -f watchdog-info.json
rm -f connection-info.json

# 5. Restart all supervisor services
echo "Limpinho restarted processes"
supervisorctl restart all

echo "Limped very nice."
