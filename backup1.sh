#!/bin/bash

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run this script as root (sudo bash setup_restic.sh)"
  exit 1
fi

echo "========================================================="
echo "        RESTIC AUTOMATED BACKUP SETUP SCRIPT            "
echo "========================================================="
echo ""

# 1. Install Dependencies
echo "🔄 Updating package lists and installing Restic & CIFS tools..."
apt-get update -y && apt-get install -y restic cifs-utils
echo "✅ Dependencies installed."
echo "---------------------------------------------------------"

# 2. Collect Backup Source Directory
echo "📂 Q&A: Source Directory"
read -p "🔹 Enter the absolute path of the folder you want to backup (e.g., /var/www): " BACKUP_SOURCE

# Verify the directory exists before proceeding
while [ ! -d "$BACKUP_SOURCE" ] || [ -z "$BACKUP_SOURCE" ]; do
    echo "⚠️ Directory '$BACKUP_SOURCE' does not exist or invalid."
    read -p "🔹 Please enter a valid absolute path: " BACKUP_SOURCE
done
echo "---------------------------------------------------------"

# 3. Collect SMB/NAS Configuration
echo "📝 Q&A: SMB NAS Configuration"
read -p "🔹 Enter NAS IP or Hostname (e.g., 192.168.1.50): " NAS_IP
read -p "🔹 Enter SMB Share Name (e.g., backups): " NAS_SHARE
read -p "🔹 Enter Subfolder for THIS server (e.g., server1): " NAS_SUBFOLDER
read -p "🔹 Enter SMB Username: " SMB_USER
read -s -p "🔹 Enter SMB Password: " SMB_PASS
echo ""
echo "---------------------------------------------------------"

# 4. Setup SMB Mount Points and Credentials
MOUNT_POINT="/mnt/restic_nas"
mkdir -p "$MOUNT_POINT"

SMB_CRED_FILE="/root/.smbcredentials_restic"
cat << EOF > "$SMB_CRED_FILE"
username=$SMB_USER
password=$SMB_PASS
EOF
chmod 600 "$SMB_CRED_FILE"

# Construct fstab line (using nobrl for performance on millions of files)
FSTAB_LINE="//$NAS_IP/$NAS_SHARE /$MOUNT_POINT cifs credentials=$SMB_CRED_FILE,iocharset=utf8,vers=3.0,nobrl,nofail 0 0"

# Append to fstab if not already present
if ! grep -q "//$NAS_IP/$NAS_SHARE" /etc/fstab; then
    echo "$FSTAB_LINE" >> /etc/fstab
    echo "💾 Added SMB share to /etc/fstab"
else
    echo "ℹ️ SMB share already exists in /etc/fstab, skipping append."
fi

echo "🔄 Mounting SMB share..."
mount -a
if [ $? -ne 0 ]; then
    echo "❌ Failed to mount SMB share. Please check your credentials and network."
    exit 1
fi

REPO_PATH="$MOUNT_POINT/$NAS_SUBFOLDER"
mkdir -p "$REPO_PATH"
echo "✅ SMB Share mounted successfully at $MOUNT_POINT"
echo "---------------------------------------------------------"

# 5. Initialize Restic Repository (Using SMB Password for Encryption)
echo "📁 Configuring Restic Repository..."
PW_FILE="/root/.restic_password"

# Set the restic encryption key identical to the NAS password
echo "$SMB_PASS" > "$PW_FILE"
chmod 600 "$PW_FILE"

export RESTIC_PASSWORD_FILE="$PW_FILE"
if ! restic -r "$REPO_PATH" snapshots >/dev/null 2>&1; then
    echo "📦 Initializing a new Restic repository at $REPO_PATH using your NAS password..."
    restic -r "$REPO_PATH" init
else
    echo "ℹ️ Restic repository already initialized at this location."
fi
echo "---------------------------------------------------------"

# 6. Create Systemd Service and Timer (4-Hour Schedule)
echo "⚙️ Creating automated systemd background services..."

# Create the backup execution script
BACKUP_SCRIPT="/usr/local/bin/restic-run-backup.sh"
cat << EOF > "$BACKUP_SCRIPT"
#!/bin/bash
export RESTIC_PASSWORD_FILE="$PW_FILE"
# Run backup, caching files locally to keep scanning speeds ultra-fast
restic -r "$REPO_PATH" backup "$BACKUP_SOURCE" --exclude-caches
# Clean up old snapshots to manage space (Keep last 7 days of 4-hour backups, 4 weeks)
restic -r "$REPO_PATH" forget --keep-daily 7 --keep-weekly 4 --prune
EOF
chmod +x "$BACKUP_SCRIPT"

# Create Systemd Service
cat << EOF > /etc/systemd/system/restic-backup.service
[Unit]
Description=Restic 4-Hour Automated Backup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$BACKUP_SCRIPT
EOF

# Create Systemd Timer (Triggers every 4 hours)
cat << EOF > /etc/systemd/system/restic-backup.timer
[Unit]
Description=Run Restic Backup Every 4 Hours

[Timer]
OnBootSec=10min
OnUnitActiveSec=4h
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Reload and Enable Services
systemctl daemon-reload
systemctl enable --now restic-backup.timer

echo "========================================================="
echo "🎉 SETUP COMPLETE SUCCESSFULLY!"
echo "========================================================="
echo "📊 Folder '$BACKUP_SOURCE' is now scheduled to back up every 4 hours."
echo "🔐 Note: The Restic repository password matches your NAS password."
echo "🔍 To check the status of your timer, run:"
echo "   systemctl status restic-backup.timer"
echo ""
echo "📈 To view the live backup log or troubleshoot, run:"
echo "   journalctl -u restic-backup.service -f"
echo "========================================================="
