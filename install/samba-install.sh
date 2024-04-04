#!/usr/bin/env bash
apt update
apt install samba -y

# Stop samba
service smbd stop

# Create samba user
groupadd --system samba
useradd --system --group samba

# Create the share drive
mkdir /home/samba/share

# Backup existing config
mv /etc/samba/smb.conf /etc/samba/backup-smb.conf

# Copy our config
cp ./sambaconfig.conf /etc/samba/smb.conf

# Allow Samba through firewall
ufw allow samba

# Samba Starts on Restart
service smbd enable

# Restart Service
service smbd restart
