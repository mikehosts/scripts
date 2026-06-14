#!/bin/bash
# Pterodactyl NAS Sync Installer - Single File Edition

set -e

[[ $EUID -ne 0 ]] && { echo "Run as root"; exit 1; }

SOURCE="/var/lib/pterodactyl"
MOUNT="/mnt/pterodactyl_nas"

echo "=== Pterodactyl NAS Sync Installer ==="

read -rp "NAS IP/Hostname: " NAS_IP
read -rp "NAS Share Name: " NAS_SHARE
read -rp "NAS Username: " NAS_USER
read -rsp "NAS Password: " NAS_PASS
echo
read -rp "Destination folder on NAS: " DEST_FOLDER

read -rp "Source folder [$SOURCE]: " TMP
[[ -n "$TMP" ]] && SOURCE="$TMP"

THREADS=$(nproc)
RAM_GB=$(free -g | awk '/Mem:/ {print $2}')

THREAD75=$(( THREADS * 75 / 100 ))
[[ $THREAD75 -lt 1 ]] && THREAD75=1

echo
echo "Detected $THREADS CPU threads and ${RAM_GB}GB RAM"
echo "1) Use all threads ($THREADS)"
echo "2) Use 75% ($THREAD75)"
echo "3) Custom"

read -rp "Choice [2]: " CHOICE

case "$CHOICE" in
  1) LSYNCD_THREADS=$THREADS ;;
  3) read -rp "Custom thread count: " LSYNCD_THREADS ;;
  *) LSYNCD_THREADS=$THREAD75 ;;
esac

if (( RAM_GB >= 128 )); then
  WATCHES=67108864
elif (( RAM_GB >= 64 )); then
  WATCHES=33554432
else
  WATCHES=16777216
fi

apt-get update
apt-get install -y lsyncd rsync cifs-utils

mkdir -p "$MOUNT"

cat >/root/.nas-credentials <<EOF
username=$NAS_USER
password=$NAS_PASS
EOF
chmod 600 /root/.nas-credentials

mount_success=0
for VER in 3.1.1 3.0 2.1; do
    umount "$MOUNT" >/dev/null 2>&1 || true

    if mount -t cifs "//$NAS_IP/$NAS_SHARE" "$MOUNT" \
      -o "credentials=/root/.nas-credentials,vers=$VER,_netdev,noserverino,mfsymlinks"; then
        SMB_VER="$VER"
        mount_success=1
        break
    fi
done

if [[ $mount_success -ne 1 ]]; then
    echo "Failed to mount NAS."
    exit 1
fi

grep -q "$MOUNT" /etc/fstab || \
echo "//$NAS_IP/$NAS_SHARE $MOUNT cifs credentials=/root/.nas-credentials,vers=$SMB_VER,_netdev,nofail,noserverino,mfsymlinks 0 0" >> /etc/fstab

cat >/etc/sysctl.d/99-pterodactyl-sync.conf <<EOF
fs.inotify.max_user_watches=$WATCHES
fs.inotify.max_user_instances=2097152
fs.inotify.max_queued_events=8388608
fs.file-max=134217728
vm.max_map_count=1048576
EOF

sysctl --system >/dev/null

DEST="$MOUNT/$DEST_FOLDER"
mkdir -p "$DEST"

cat >/etc/lsyncd/lsyncd.conf.lua <<EOF
settings {
 logfile="/var/log/lsyncd.log",
 statusFile="/var/log/lsyncd.status",
 nodaemon=false,
 insist=true,
 maxProcesses=$LSYNCD_THREADS,
 maxDelays=100000
}

sync {
 default.rsync,
 source="$SOURCE",
 target="$DEST",
 rsync={
   archive=true,
   compress=false,
   delete=true,
   _extra={
     "--backup",
     "--backup-dir=$DEST/deleted/" .. os.date("%Y/%m/%d")
   }
 }
}
EOF

cat >/usr/local/bin/pterodactyl-nas-watchdog.sh <<'EOF'
#!/bin/bash
if mountpoint -q /mnt/pterodactyl_nas; then
    systemctl is-active --quiet lsyncd || systemctl start lsyncd
else
    systemctl is-active --quiet lsyncd && systemctl stop lsyncd
fi
EOF

chmod +x /usr/local/bin/pterodactyl-nas-watchdog.sh

cat >/etc/systemd/system/pterodactyl-nas-watchdog.service <<'EOF'
[Unit]
Description=Pterodactyl NAS Watchdog

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pterodactyl-nas-watchdog.sh
EOF

cat >/etc/systemd/system/pterodactyl-nas-watchdog.timer <<'EOF'
[Unit]
Description=Run NAS watchdog every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable pterodactyl-nas-watchdog.timer
systemctl start pterodactyl-nas-watchdog.timer

read -rp "Run initial sync now? (y/n): " RUNSYNC

if [[ "$RUNSYNC" =~ ^[Yy]$ ]]; then
    rsync -aHAX --numeric-ids --info=progress2 "$SOURCE/" "$DEST/"
fi

systemctl enable lsyncd
systemctl restart lsyncd

echo
echo "Installed successfully."
echo "Source: $SOURCE"
echo "Destination: $DEST"
echo "SMB Version: $SMB_VER"
echo "Threads: $LSYNCD_THREADS"
