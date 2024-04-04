#!/usr/bin/env bash

sudo sh ./samba-install.sh
(crontab -l 2>/dev/null; echo "*/5 * * * /home/docucat/install/consume.sh") | crontab -
(crontab -l 2>/dev/null; echo "*/5 * * * /home/docucat/install/backup.sh") | crontab -

sh install-paperless-ngx.sh
