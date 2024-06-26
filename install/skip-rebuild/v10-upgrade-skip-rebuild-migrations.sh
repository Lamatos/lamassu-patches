#!/usr/bin/env bash
set -e

trap 'cleanup $? $LINENO' EXIT

timestamp=$(date +'%Y%m%d%H%M%S')
export LOG_FILE=/tmp/update.${timestamp}.log

if [[ -z "${NODE_ENV}" ]]; then
  # Set NODE_ENV on this terminal session and system-wide
  export NODE_ENV=production
  echo 'export NODE_ENV=production' >> /etc/environment
fi

SCRIPTPATH="$( cd "$(dirname "$0")" ; pwd -P )"
UBUNTU_VERSION=$(lsb_release -rs)
NODE_MODULES=$(npm -g root)
export NPM_BIN=$(npm -g bin)

rm -f ${LOG_FILE}

decho () {
  echo `date +"%H:%M:%S"` $1
  echo `date +"%H:%M:%S"` $1 >> ${LOG_FILE}
}

cleanup () {
  exit_code="$1"
  if [ "${exit_code}" != "0" ]; then
    lineno="$2"
    decho "There was a error on line ${lineno} (exit code ${exit_code})"
    decho
    decho 'The upgrade has been halted due to an error. You may run the upgrade script again in case this resolves the problem.'
    decho
    decho 'If you receive this message again, please reach out to our support team.'
  fi
  rm -f /var/lock/lamassu-update
}

cat <<'FIG'
 _
| | __ _ _ __ ___   __ _ ___ ___ _   _       ___  ___ _ ____   _____ _ __
| |/ _` | '_ ` _ \ / _` / __/ __| | | |_____/ __|/ _ \ '__\ \ / / _ \ '__|
| | (_| | | | | | | (_| \__ \__ \ |_| |_____\__ \  __/ |   \ V /  __/ |
|_|\__,_|_| |_| |_|\__,_|___/___/\__,_|     |___/\___|_|    \_/ \___|_|
FIG

echo -e "\nStarting \033[1mlamassu-server\033[0m update. This will take a few minutes...\n"

if [ "$(whoami)" != "root" ]; then
  echo -e "This script has to be run as \033[1mroot\033[0m user"
  exit 3
fi

# Use a lock file so failed scripts cannot be imediately retried
# If not the backup created on this script would be replaced
if ! mkdir /var/lock/lamassu-update; then
  echo "It seems the script is already running. Aborting." >&2
  trap "" EXIT # Don't remove another script's lock
  exit 1
fi

if [[ "$UBUNTU_VERSION" == "20.04" ]]; then
  echo -e "\033[1mDetected Ubuntu version: 20.04. Your operating system is up to date.\033[0m"
  echo
  echo -e "\033[1mUpdating lamassu-server to v10.0.0-rc.4...\033[0m"
  echo

  # Check if ETH was transacted for the first time before 8.0
  SERVER_RELEASE=$(node -p -e "require('$(npm root -g)/lamassu-server/package.json').version")

  # SERVER_RELEASE should be empty if the command fails, such as if the file doesn't exist
  if [ ${SERVER_RELEASE} = "" ] || [ $(printf "%s\n" "$SERVER_RELEASE" "8.0.0" | sort -V | head -1) = "$SERVER_RELEASE" ] || [ "$SERVER_RELEASE" = "8.0.0-beta.6" ]
  then
    : # no-op, ETH issue is fixed or never occurred when on these versions. sort -V considers 8.0.0 < 8.0.0-beta.X, hence the extra check
  elif [ $(printf "%s\n" "$SERVER_RELEASE" "8.0.0-beta.5" | sort -V | head -1) = "$SERVER_RELEASE" ]
  then
    if [ -d /var/lock/lamassu-eth-pending-sweep-finished ]; then
      : # no-op, continue the upgrade
    elif ! mkdir /var/lock/lamassu-eth-pending-sweep; then
      echo "Upgrading l-s is locked because of an intended halt. Please contact support for more info" >&2
      rmdir /var/lock/lamassu-update
      exit 1
    else
      CONFIG_DIR=/etc/lamassu
      CONNECTION_STRING_TEMP=$(grep -oP '(?<="postgresql": ")[^"]*' $CONFIG_DIR/lamassu.json)
      CONNECTION_STRING=$(echo "${CONNECTION_STRING_TEMP/psql/"postgresql"}")

      FIRST_FF_MIGRATION_TIME=$(psql -d $CONNECTION_STRING -Atc "SELECT value->>'timestamp' FROM migrations m, json_array_elements(m.data->'migrations') obj WHERE obj->>'title' = '1603804834628-add-last-accessed-tokens.js';")
      FIRST_ETH_TX_TIME=$(psql -d $CONNECTION_STRING -Atc "SELECT EXTRACT(EPOCH FROM created) * 1000 FROM (SELECT id, crypto_code, created FROM cash_in_txs UNION SELECT id, crypto_code, created FROM cash_out_txs) txs WHERE txs.crypto_code = 'ETH' ORDER BY created ASC LIMIT 1;")

      if [ -z "${FIRST_ETH_TX_TIME}" ]; then
        : # no-op, continue the upgrade
      elif [ $FIRST_ETH_TX_TIME \> $FIRST_FF_MIGRATION_TIME ]; then
        echo -e "\n\033[0;31mAn Ethereum transaction was detected to have been made for the first time after the v8.0 beta upgrade.\n\nThis is okay and funds are safe, but it will require a unique update path. In order to continue, please contact support for specific update instructions.\n\nMeanwhile, your server and machine(s) continue to run on their current versions.\033[0m\n"
#        curl -o $(npm root -g)/lamassu-server/bin/lamassu-eth-sweep-to-new-wallet https://raw.githubusercontent.com/lamassu/lamassu-server/release-8.0/bin/lamassu-eth-sweep-to-new-wallet >> ${LOG_FILE} 2>&1
        rmdir /var/lock/lamassu-update
        exit 1
      fi
      rmdir /var/lock/lamassu-eth-pending-sweep
    fi
  fi

  decho "stopping lamassu-server"
  supervisorctl stop lamassu-server >> ${LOG_FILE} 2>&1
  supervisorctl stop lamassu-admin-server >> ${LOG_FILE} 2>&1

  decho "updating nodejs"
  apt install -y nodejs >> ${LOG_FILE} 2>&1

  decho "unlinking old executables"
  set +e
  rm $NPM_BIN/lamassu-* >> ${LOG_FILE} 2>&1
  rm $NPM_BIN/hkdf >> ${LOG_FILE} 2>&1
  rm $NPM_BIN/bip39 >> ${LOG_FILE} 2>&1
  set -e

  if [ -d "/usr/lib/node_modules/lamassu-server" ]; then
      BKP_NAME=lamassu-server-${timestamp}
      decho "renaming old lamassu-server instance to ${BKP_NAME}"
      mv -v "${NODE_MODULES}/lamassu-server" "${NODE_MODULES}/${BKP_NAME}" >> ${LOG_FILE} 2>&1
  fi

  decho "updating lamassu-server to v10.0.0-rc.4..."
  sourceHash=$'1c48b0e6b51b4b1ec9d9383ba4c78edd40b25cff8526d8573b478e33ed4d60cd'
  curl -sSLo /tmp/lamassu-server.tar.gz https://github.com/lamassu/lamassu-server/releases/download/v10.0.0-rc.4/lamassu-server-v10.0.0-rc.4.tar.gz >> $LOG_FILE 2>&1
  hash=$(sha256sum /tmp/lamassu-server.tar.gz | awk '{print $1}' | sed 's/ *$//g')

  if [ $hash != $sourceHash ] ; then
      echo 'Package signature does not match!'
      exit 1
  fi

  tar -xzf /tmp/lamassu-server.tar.gz -C $NODE_MODULES/ >> $LOG_FILE 2>&1

  decho "Creating symlinks..."
  cp -s $NODE_MODULES/lamassu-server/bin/lamassu-* $NPM_BIN/ >> ${LOG_FILE} 2>&1
  cp -s $NODE_MODULES/lamassu-server/bin/hkdf $NPM_BIN/ >> ${LOG_FILE} 2>&1
  cp -s $NODE_MODULES/lamassu-server/bin/bip39 $NPM_BIN/ >> ${LOG_FILE} 2>&1
  chmod +x $NODE_MODULES/lamassu-server/bin/* >> ${LOG_FILE} 2>&1

  # decho "rebuilding npm deps"
  cd $(npm root -g)/lamassu-server/ >> ${LOG_FILE} 2>&1
  # npm rebuild >> ${LOG_FILE} 2>&1

  CONFIG_DIR=/etc/lamassu

  if [ ! -f $CONFIG_DIR/.env ]; then
    decho "Environment file not found, creating one..."
    touch $CONFIG_DIR/.env
    decho "Creating environment symlink..."
    cp --symbolic-link $CONFIG_DIR/.env $NODE_MODULES/lamassu-server/.env >> $LOG_FILE 2>&1
    OPTIONS_POSTGRES_PW=$(grep -oP '(?<="postgresql": ")[^"]*' $CONFIG_DIR/lamassu.json | sed -nr 's/.*:(.*)@.*/\1/p')
    OPTIONS_HOSTNAME=$(grep -oP '(?<="hostname": ")[^"]*' $CONFIG_DIR/lamassu.json)
    node $NODE_MODULES/lamassu-server/tools/build-prod-env.js --db-password $OPTIONS_POSTGRES_PW --hostname $OPTIONS_HOSTNAME
  else
    decho "Creating environment symlink..."
    cp --symbolic-link $CONFIG_DIR/.env $NODE_MODULES/lamassu-server/.env >> $LOG_FILE 2>&1
  fi

  # {
  # decho "running migration"
  #  lamassu-migrate >> ${LOG_FILE} 2>&1
  # } || { echo "Failure running migrations" ; exit 1 ; }

  decho "update to mnemonic"
  lamassu-update-to-mnemonic --prod >> ${LOG_FILE} 2>&1

  decho "update ofac sources"
  lamassu-ofac-update-sources >> ${LOG_FILE} 2>&1

  decho "updating supervisor conf"
  perl -i -pe 's/command=.*/command=$ENV{NPM_BIN}\/lamassu-server/g' /etc/supervisor/conf.d/lamassu-server.conf >> ${LOG_FILE} 2>&1
  perl -i -pe 's/command=.*/command=$ENV{NPM_BIN}\/lamassu-admin-server/g' /etc/supervisor/conf.d/lamassu-admin-server.conf >> ${LOG_FILE} 2>&1
  perl -i -pe 's/environment=.*/environment=HOME="\/root",NODE_ENV="production"/g' /etc/supervisor/conf.d/lamassu-server.conf >> ${LOG_FILE} 2>&1
  perl -i -pe 's/environment=.*/environment=HOME="\/root",NODE_ENV="production"/g' /etc/supervisor/conf.d/lamassu-admin-server.conf >> ${LOG_FILE} 2>&1
  cat <<EOF >> /etc/supervisor/supervisord.conf
[inet_http_server]
port = 127.0.0.1:9001
EOF

  decho "updating lamassu-server"
  supervisorctl update >> ${LOG_FILE} 2>&1
  supervisorctl start lamassu-server >> ${LOG_FILE} 2>&1
  supervisorctl start lamassu-admin-server >> ${LOG_FILE} 2>&1

  decho "updating backups conf"
  BACKUP_CMD=${NPM_BIN}/lamassu-backup-pg
  BACKUP_CRON="@daily $BACKUP_CMD > /dev/null"
  ( (crontab -l 2>/dev/null || echo -n "") | grep -v '@daily.*lamassu-backup-pg'; echo $BACKUP_CRON ) | crontab - >> $LOG_FILE 2>&1
  $BACKUP_CMD >> $LOG_FILE 2>&1

  decho "updating motd scripts"
  set +e
  chmod -x /etc/update-motd.d/*-release-upgrade 2>/dev/null
  chmod -x /etc/update-motd.d/*-updates-available 2>/dev/null
  chmod -x /etc/update-motd.d/*-reboot-required 2>/dev/null
  chmod -x /etc/update-motd.d/*-help-text 2>/dev/null
  chmod -x /etc/update-motd.d/*-cloudguest 2>/dev/null
  chmod -x /etc/update-motd.d/*-motd-news 2>/dev/null
  set -e

  decho "updating installed wallet nodes"
  lamassu-update-wallet-nodes >> ${LOG_FILE} 2>&1

  echo
  echo -e "\033[1mLamassu server update complete!\033[0m"
  echo
else
  echo
  echo -e "\033[0;31mOld Ubuntu version detected ($UBUNTU_VERSION). Make sure that Ubuntu is on either version 16.04 or 18.04 and update it.\033[0m"
  echo "To update this machine's operating system, please run the following command in this machine's terminal:"
  echo
  echo -e "\033[1mcurl -sS https://raw.githubusercontent.com/lamassu/lamassu-install/electric-enlil/upgrade-os | bash\033[0m"
  echo
fi

# reset terminal to link new executables
hash -r

rmdir /var/lock/lamassu-update

if [ -d /var/lock/lamassu-eth-pending-sweep-finished ]; then
  rmdir /var/lock/lamassu-eth-pending-sweep-finished
fi
