#!/bin/bash

##############################################################################
# PTERODACTYL NAS SYNC INSTALLER
# Installs:
# - cifs-utils
# - rsync
# - lsyncd
#
# Creates:
# - SMB mount
# - Credentials file
# - /etc/fstab entry
# - lsyncd config
# - systemd service
#
# Usage:
#   sudo ./install-sync.sh
#
##############################################################################

set -e

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root:"
    echo "sudo $0"
    exit 1
fi

clear

echo "=================================================="
echo "      PTERODACTYL NAS SYNC INSTALLER"
echo "=================================================="
echo

read_yes_no() {
    while true; do
        read -rp "$1 (y/n): " yn

        case "$yn" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

##############################################################################
# DEFAULTS
##############################################################################

SOURCE_DIR="/var/lib/pterodactyl"
MOUNT_POINT="/mnt/nas"

##############################################################################
# QUESTIONS
##############################################################################

if read_yes_no "Is the NAS already mounted"; then
    NAS_MOUNTED="yes"

    read -rp "Existing mount path [$MOUNT_POINT]: " TMP
    [ -n "$TMP" ] && MOUNT_POINT="$TMP"

else
    NAS_MOUNTED="no"

    echo
    echo "NAS SETTINGS"
    echo "------------"

    read -rp "NAS IP or Hostname: " NAS_IP
    read -rp "Share Name: " NAS_SHARE
    read -rp "Username: " NAS_USER
    read -rsp "Password: " NAS_PASS
    echo

    read -rp "Mount path [$MOUNT_POINT]: " TMP
    [ -n "$TMP" ] && MOUNT_POINT="$TMP"
fi

echo

read -rp "Source directory [$SOURCE_DIR]: " TMP
[ -n "$TMP" ] && SOURCE_DIR="$TMP"

echo

read -rp "Destination folder inside NAS share: " DEST_FOLDER

while [ -z "$DEST_FOLDER" ]; do
    echo "Destination folder cannot be empty."
    read -rp "Destination folder inside NAS share: " DEST_FOLDER
done

echo

if read_yes_no "Archive deleted files"; then
    ARCHIVE_DELETES="yes"
else
    ARCHIVE_DELETES="no"
fi

echo

if read_yes_no "Enable autostart on boot"; then
    AUTOSTART="yes"
else
    AUTOSTART="no"
fi

echo
echo "=================================================="
echo "SUMMARY"
echo "=================================================="
echo "Source:            $SOURCE_DIR"
echo "Mount Point:       $MOUNT_POINT"
echo "Destination:       $DEST_FOLDER"
echo "Archive Deletes:   $ARCHIVE_DELETES"
echo "Autostart:         $AUTOSTART"

if [ "$NAS_MOUNTED" = "no" ]; then
    echo "NAS: //$NAS_IP/$NAS_SHARE"
fi

echo

if ! read_yes_no "Proceed with installation"; then
    echo "Cancelled."
    exit 0
fi

##############################################################################
# INSTALL PACKAGES
##############################################################################

echo
echo "[1/7] Installing packages..."

apt-get update
apt-get install -y cifs-utils rsync lsyncd

##############################################################################
# SMB SETUP
##############################################################################

if [ "$NAS_MOUNTED" = "no" ]; then

    echo
    echo "[2/7] Configuring SMB mount..."

    mkdir -p "$MOUNT_POINT"

    cat > /root/.nas-credentials <<EOF
username=$NAS_USER
password=$NAS_PASS
EOF

    chmod 600 /root/.nas-credentials

    FSTAB_LINE="//$NAS_IP/$NAS_SHARE $MOUNT_POINT cifs credentials=/root/.nas-credentials,vers=3.0,_netdev,nofail 0 0"

    if ! grep -Fq "$MOUNT_POINT" /etc/fstab; then
        echo "$FSTAB_LINE" >> /etc/fstab
    fi

    mount -a

    sleep 2

    if ! mountpoint -q "$MOUNT_POINT"; then
        echo
        echo "ERROR: SMB share failed to mount."
        exit 1
    fi
fi

##############################################################################
# CREATE DESTINATION
##############################################################################

echo
echo "[3/7] Creating destination..."

DEST="$MOUNT_POINT/$DEST_FOLDER"

mkdir -p "$DEST"

if [ "$ARCHIVE_DELETES" = "yes" ]; then
    mkdir -p "$DEST/deleted"
fi

##############################################################################
# CREATE LSYNCD CONFIG
##############################################################################

echo
echo "[4/7] Creating lsyncd config..."

mkdir -p /etc/lsyncd

if [ "$ARCHIVE_DELETES" = "yes" ]; then

cat > /etc/lsyncd/lsyncd.conf.lua <<EOF
settings {
    logfile = "/var/log/lsyncd.log",
    statusFile = "/var/log/lsyncd.status",
    nodaemon = false,
}

sync {
    default.rsync,
    source = "$SOURCE_DIR",
    target = "$DEST",

    rsync = {
        archive = true,
        compress = false,
        delete = true,

        _extra = {
            "--backup",
            "--backup-dir=$DEST/deleted"
        }
    }
}
EOF

else

cat > /etc/lsyncd/lsyncd.conf.lua <<EOF
settings {
    logfile = "/var/log/lsyncd.log",
    statusFile = "/var/log/lsyncd.status",
    nodaemon = false,
}

sync {
    default.rsync,
    source = "$SOURCE_DIR",
    target = "$DEST",

    rsync = {
        archive = true,
        compress = false,
        delete = true
    }
}
EOF

fi

##############################################################################
# INITIAL SYNC
##############################################################################

echo
echo "[5/7] Running initial sync..."

rsync -a "$SOURCE_DIR/" "$DEST/"

##############################################################################
# ENABLE SERVICE
##############################################################################

echo
echo "[6/7] Configuring service..."

systemctl daemon-reload

if [ "$AUTOSTART" = "yes" ]; then
    systemctl enable lsyncd
fi

systemctl restart lsyncd

##############################################################################
# VERIFY
##############################################################################

echo
echo "[7/7] Verification..."

sleep 2

if systemctl is-active --quiet lsyncd; then
    STATUS="RUNNING"
else
    STATUS="FAILED"
fi

echo
echo "=================================================="
echo "INSTALLATION COMPLETE"
echo "=================================================="
echo
echo "Service Status: $STATUS"
echo
echo "Source:"
echo "  $SOURCE_DIR"
echo
echo "Destination:"
echo "  $DEST"
echo

if [ "$ARCHIVE_DELETES" = "yes" ]; then
    echo "Deleted files:"
    echo "  $DEST/deleted"
    echo
fi

echo "Useful Commands:"
echo
echo "systemctl status lsyncd"
echo "systemctl restart lsyncd"
echo "tail -f /var/log/lsyncd.log"
echo
echo "Done."
