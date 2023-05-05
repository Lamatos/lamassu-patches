#!/bin/bash

cd /etc/supervisor/conf.d/

sed -i 's,command=/usr/local/bin/lamassu-server,command=/usr/bin/lamassu-server,g' lamassu-server.conf

sed -i 's,command=/usr/local/bin/lamassu-admin-server,command=/usr/bin/lamassu-admin-server,g' lamassu-admin-server.conf

echo
echo "Conf files edited successfully. Continuing..."
echo

cd /usr/local/bin 

ln -sf -n /usr/lib/node_modules/lamassu-server/bin/lamassu-admin-server lamassu-admin-server

ln -sf -n /usr/lib/node_modules/lamassu-server/bin/lamassu-server lamassu-server

supervisorctl update

echo
echo "All done."
echo
