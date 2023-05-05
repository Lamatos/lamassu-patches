#!/bin/bash

cd /etc/supervisor/conf.d/

sed -i 's,command=/usr/bin/lamassu-server,command=/usr/local/bin/lamassu-server,g' lamassu-server.conf

sed -i 's,command=/usr/bin/lamassu-admin-server,command=/usr/local/bin/lamassu-admin-server,g' lamassu-admin-server.conf

echo
echo "Done."
echo
