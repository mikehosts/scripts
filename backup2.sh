#!/usr/bin/env bash
# ==============================================================================
# Pterodactyl -> NAS Real-Time Sync Enterprise Installer
# ==============================================================================
# Priority: Single-file | Real-time | Auto-recovery | Scale | Deployment Ease
# Warning: The user explicitly accepts risk for this enterprise deployment.
# ==============================================================================

set -Eeuo pipefail

# --- Globals ---
LOG_FILE="/var/log/pterodactyl-sync-installer.log"
CRED_FILE="/root/.nas-credentials"
WATCHDOG_LOG="/var/log/pterodactyl-sync-watchdog.log"
LSYNCD_LOG="/var/log/lsyncd.log"
NAS_MOUNT="/mnt/ptero_nas"
RSYNC_WRAPPER="/usr/local/bin/ptero-rsync-wrapper.sh"
WATCHDOG_SCRIPT="/usr/local/bin/pterodactyl-sync-watchdog.sh"
RETENTION_SCRIPT="/usr/local/bin/pterodactyl-sync-retention.sh"
PROFILE_ALERT="/etc/profile.d/ptero-sync-alert.sh"

# --- Formatting ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${CYAN}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"; }
err() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"; exit 1; }

# ==============================================================================
# Maintenance Commands
# ==============================================================================
do_status() {
    echo -e "${CYAN}=== Pterodactyl NAS Sync Status ===${NC}"
    echo -n "NAS Mount: "
    if mountpoint -q "$NAS_MOUNT"; then echo -e "${GREEN}Mounted${NC}"; else echo -e "${RED}Not Mounted${NC}"; fi
    echo -n "lsyncd Service: "
    if systemctl is-active --quiet lsyncd; then echo -e "${GREEN}Running${NC}"; else echo -e "${RED}Stopped${NC}"; fi
    echo -n "Watchdog Timer: "
    if systemctl is-active --quiet ptero-watchdog.timer; then echo -e "${GREEN}Running${NC}"; else echo -e "${RED}Stopped${NC}"; fi
    if mountpoint -q "$NAS_MOUNT"; then
        SPACE=$(df -h "$NAS_MOUNT" | awk 'NR==2 {print $4}')
        echo -e "Free Space: ${GREEN}$SPACE${NC}"
    fi
    exit 0
}

do_uninstall() {
    echo -e "${YELLOW}Uninstalling Pterodactyl Sync...${NC}"
    systemctl stop lsyncd ptero-watchdog.timer ptero-watchdog.service ptero-retention.timer ptero-retention.service || true
    systemctl disable lsyncd ptero-watchdog.timer ptero-retention.timer || true
    
    rm -f /etc/systemd/system/ptero-watchdog.*
    rm -f /etc/systemd/system/ptero-retention.*
    rm -f "$WATCHDOG_SCRIPT" "$RETENTION_SCRIPT" "$RSYNC_WRAPPER"
    rm -f /etc/lsyncd/lsyncd.conf.lua
    rm -f /etc/sysctl.d/99-pterodactyl-sync.conf
    rm -f "$PROFILE_ALERT"
    rm -f /etc/logrotate.d/pterodactyl-sync
    sysctl --system >/dev/null 2>&1
    
    if mountpoint -q "$NAS_MOUNT"; then
        umount "$NAS_MOUNT"
    fi
    sed -i '\#ptero_nas#d' /etc/fstab
    
    echo -e "${GREEN}Uninstall complete. NAS data was NOT removed.${NC}"
    exit 0
}

do_repair() {
    echo -e "${CYAN}Repairing services and timers...${NC}"
    systemctl daemon-reload
    systemctl restart ptero-watchdog.timer
    systemctl restart ptero-retention.timer
    sysctl --system >/dev/null 2>&1
    echo -e "${GREEN}Repair complete. Core services reset.${NC}"
    exit 0
}

if [[ "${1:-}" == "--status" ]]; then do_status; fi
if [[ "${1:-}" == "--uninstall" ]]; then do_uninstall; fi
if [[ "${1:-}" == "--repair" ]]; then do_repair; fi

# ==============================================================================
# Pre-flight Checks & Installation
# ==============================================================================
if [[ $EUID -ne 0 ]]; then err "This script must be run as root."; fi

log "Installing dependencies (rsync, cifs-utils, lsyncd, jq, bc)..."
apt-get update -qq && apt-get install -y -qq rsync cifs-utils lsyncd jq bc acl attr

# ==============================================================================
# Configuration Gathering
# ==============================================================================
echo -e "\n${CYAN}--- Sync Configuration ---${NC}"
read -p "Source folder [/var/lib/pterodactyl]: " SOURCE_DIR
SOURCE_DIR=${SOURCE_DIR:-/var/lib/pterodactyl}
if [[ ! -d "$SOURCE_DIR" ]]; then err "Source directory $SOURCE_DIR does not exist."; fi

read -p "NAS IP/Hostname: " NAS_HOST
read -p "NAS Share Name (e.g., backups): " NAS_SHARE
read -p "NAS Target Folder (e.g., node-01) [leave empty for root of share]: " NAS_FOLDER
read -p "NAS SMB Username: " NAS_USER
read -s -p "NAS SMB Password: " NAS_PASS; echo

echo -e "\n${CYAN}--- Settings ---${NC}"
read -p "Retention days for deleted files [14]: " RETENTION_DAYS
RETENTION_DAYS=${RETENTION_DAYS:-14}

# Create Credentials
echo "username=$NAS_USER" > "$CRED_FILE"
echo "password=$NAS_PASS" >> "$CRED_FILE"
chmod 600 "$CRED_FILE"

# ==============================================================================
# Auto-Detect SMB Version & Mount
# ==============================================================================
log "Negotiating SMB version with $NAS_HOST..."
mkdir -p "$NAS_MOUNT"
SMB_VERSION=""

for v in 3.1.1 3.0 2.1; do
    if mount -t cifs -o vers=$v,credentials=$CRED_FILE "//$NAS_HOST/$NAS_SHARE" "$NAS_MOUNT" 2>/dev/null; then
        SMB_VERSION=$v
        log "Successfully connected using SMB $SMB_VERSION"
        break
    fi
done

if [[ -z "$SMB_VERSION" ]]; then err "Failed to connect to NAS. Check IP, Share, and Credentials."; fi

# Verify Writable
if ! touch "$NAS_MOUNT/.test_write" 2>/dev/null; then err "NAS is mounted but not writable."; fi
rm -f "$NAS_MOUNT/.test_write"

# Fstab configuration
sed -i '\#ptero_nas#d' /etc/fstab
echo "//$NAS_HOST/$NAS_SHARE $NAS_MOUNT cifs vers=$SMB_VERSION,credentials=$CRED_FILE,iocharset=utf8,noperm 0 0" >> /etc/fstab

# Setup Sync Target Directory
NAS_FOLDER=$(echo "$NAS_FOLDER" | sed -e 's/^\/*//' -e 's/\/*$//') # Strip leading/trailing slashes
if [[ -n "$NAS_FOLDER" ]]; then
    SYNC_TARGET="$NAS_MOUNT/$NAS_FOLDER"
    log "Creating target folder on NAS: $NAS_FOLDER"
    mkdir -p "$SYNC_TARGET"
else
    SYNC_TARGET="$NAS_MOUNT"
fi

# Check Existing Data
if [[ -d "$SYNC_TARGET" ]] && [[ -n "$(ls -A "$SYNC_TARGET" 2>/dev/null)" ]]; then
    warn "Destination folder ($SYNC_TARGET) contains data."
    read -p "Continue anyway? (y/n): " cont
    if [[ "$cont" != "y" ]]; then umount "$NAS_MOUNT"; exit 1; fi
fi

# ==============================================================================
# Analysis Phase
# ==============================================================================
log "Analyzing source data. This may take a moment for millions of files..."
FILE_COUNT=$(find "$SOURCE_DIR" -type f | wc -l)
DIR_COUNT=$(find "$SOURCE_DIR" -type d | wc -l)
SOURCE_KB=$(du -sk "$SOURCE_DIR" | cut -f1)
SOURCE_GB=$(echo "scale=2; $SOURCE_KB / 1024 / 1024" | bc)
NAS_KB_FREE=$(df -P "$NAS_MOUNT" | awk 'NR==2 {print $4}')
NAS_GB_FREE=$(echo "scale=2; $NAS_KB_FREE / 1024 / 1024" | bc)

echo -e "\n${CYAN}--- Initial Analysis ---${NC}"
echo -e "Files:       $FILE_COUNT"
echo -e "Directories: $DIR_COUNT"
echo -e "Size:        ${SOURCE_GB} GB"
echo -e "NAS Free:    ${NAS_GB_FREE} GB"

if (( SOURCE_KB > NAS_KB_FREE )); then
    warn "NAS FREE SPACE IS LESS THAN SOURCE SIZE!"
    read -p "Continue anyway? (y/n): " space_cont
    if [[ "$space_cont" != "y" ]]; then exit 1; fi
fi

# ==============================================================================
# CPU & RAM Tuning (Extreme Mode)
# ==============================================================================
log "Tuning System Resources..."
THREADS=$(nproc)
LOAD=$(awk '{print $1}' /proc/loadavg)
LOAD_PCT=$(echo "scale=2; ($LOAD / $THREADS) * 100" | bc | cut -d. -f1)
REC_THREADS=$(echo "scale=0; $THREADS * 0.8 / 1" | bc)

echo -e "\nDetected Threads: $THREADS"
echo -e "Current CPU Usage: ${LOAD_PCT}%"

MAX_PROCS=$REC_THREADS
if [[ $LOAD_PCT -lt 50 ]]; then
    echo "1) Recommended ($REC_THREADS threads)"
    echo "2) All Threads ($THREADS threads)"
    echo "3) Custom"
    read -p "Select CPU maxProcesses for lsyncd [1]: " cpu_choice
    case ${cpu_choice:-1} in
        2) MAX_PROCS=$THREADS ;;
        3) read -p "Enter number of threads: " MAX_PROCS ;;
        *) MAX_PROCS=$REC_THREADS ;;
    esac
fi

# RAM Tuning
RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
WATCHES=$((RAM_GB * 1000000))
[[ $WATCHES -lt 8192 ]] && WATCHES=8192
INSTANCES=$((RAM_GB * 1024))
FILEMAX=$((RAM_GB * 1000000))
MAPCOUNT=$((RAM_GB * 250000))

cat << EOF > /etc/sysctl.d/99-pterodactyl-sync.conf
fs.inotify.max_user_watches = $WATCHES
fs.inotify.max_user_instances = $INSTANCES
fs.inotify.max_queued_events = 16384000
fs.file-max = $FILEMAX
vm.max_map_count = $MAPCOUNT
EOF
sysctl --system >/dev/null 2>&1

# ==============================================================================
# Initial Sync Execution
# ==============================================================================
echo -e "\n${CYAN}--- Initial Sync ---${NC}"
read -p "Run initial sync now? (y/n): " run_sync
if [[ "$run_sync" == "y" ]]; then
    echo "1) Normal Priority"
    echo "2) Low CPU + Low IO"
    read -p "Select Priority [1]: " sync_prio
    
    PREFIX=""
    if [[ "$sync_prio" == "2" ]]; then
        PREFIX="ionice -c2 -n7 nice -n 19"
    fi
    
    log "Starting initial sync... (Resume capable, auto-recovers NAS disconnects)"
    while true; do
        if mountpoint -q "$NAS_MOUNT" && touch "$NAS_MOUNT/.write_test" 2>/dev/null; then
            rm -f "$NAS_MOUNT/.write_test"
            set +e
            $PREFIX rsync -aHAX --numeric-ids --info=progress2 \
                --exclude="*/node_modules/*" \
                "$SOURCE_DIR/" "$SYNC_TARGET/"
            RSYNC_EXIT=$?
            set -e
            
            if [[ $RSYNC_EXIT -eq 0 || $RSYNC_EXIT -eq 24 ]]; then
                log "Initial sync completed successfully."
                break
            else
                warn "Rsync interrupted (code $RSYNC_EXIT). Waiting 15 seconds to retry..."
                sleep 15
            fi
        else
            warn "NAS offline. Attempting to remount..."
            umount -l "$NAS_MOUNT" 2>/dev/null || true
            mount "$NAS_MOUNT" 2>/dev/null || true
            sleep 10
        fi
    done
fi

# ==============================================================================
# Helper Scripts Generation
# ==============================================================================
log "Generating runtime scripts..."

# 1. Rsync Wrapper (Handles real-time Deletes -> Moves to deleted/YYYY/MM/DD)
cat << EOF > "$RSYNC_WRAPPER"
#!/bin/bash
TODAY=\$(date +%Y/%m/%d)
BACKUP_DIR="$SYNC_TARGET/deleted/\$TODAY"
mkdir -p "\$BACKUP_DIR"
exec /usr/bin/rsync --backup --backup-dir="\$BACKUP_DIR" "\$@"
EOF
chmod +x "$RSYNC_WRAPPER"

# 2. Watchdog Script
cat << EOF > "$WATCHDOG_SCRIPT"
#!/bin/bash
MOUNT_POINT="$NAS_MOUNT"
ALERT_FILE="$PROFILE_ALERT"
ERROR=0
REASON=""

# Check Mount
if ! mountpoint -q "\$MOUNT_POINT"; then
    mount "\$MOUNT_POINT" || { ERROR=1; REASON="NAS Offline / Cannot Mount"; }
fi

# Check Writable
if [[ \$ERROR -eq 0 ]] && ! touch "\$MOUNT_POINT/.watchdog" 2>/dev/null; then
    ERROR=1; REASON="NAS Mounted but Read-Only";
fi
rm -f "\$MOUNT_POINT/.watchdog" 2>/dev/null

# Check Free Space
if [[ \$ERROR -eq 0 ]]; then
    FREE_KB=\$(df -P "\$MOUNT_POINT" | awk 'NR==2 {print \$4}')
    if (( FREE_KB < 1048576 )); then ERROR=1; REASON="NAS Low Space (< 1GB)"; fi
fi

# Action
if [[ \$ERROR -eq 1 ]]; then
    systemctl stop lsyncd 2>/dev/null
    echo -e "echo -e '\\033[0;31m[CRITICAL] Pterodactyl Sync: '\$REASON'\\033[0m'" > "\$ALERT_FILE"
    echo "\$(date): Failed - \$REASON" >> "$WATCHDOG_LOG"
else
    rm -f "\$ALERT_FILE"
    if ! systemctl is-active --quiet lsyncd; then
        systemctl start lsyncd
        echo "\$(date): NAS healthy. Restarted lsyncd." >> "$WATCHDOG_LOG"
    fi
fi
EOF
chmod +x "$WATCHDOG_SCRIPT"

# 3. Retention Cleanup Script
cat << EOF > "$RETENTION_SCRIPT"
#!/bin/bash
DEL_PATH="$SYNC_TARGET/deleted"
if [[ -d "\$DEL_PATH" ]]; then
    find "\$DEL_PATH" -type f -mtime +$RETENTION_DAYS -exec rm -f {} \;
    find "\$DEL_PATH" -type d -empty -delete 2>/dev/null
fi
EOF
chmod +x "$RETENTION_SCRIPT"

# ==============================================================================
# Lsyncd Configuration
# ==============================================================================
log "Generating lsyncd configuration..."
mkdir -p /etc/lsyncd
cat << EOF > /etc/lsyncd/lsyncd.conf.lua
settings {
    logfile = "$LSYNCD_LOG",
    statusFile = "/var/log/lsyncd-status.log",
    statusInterval = 20,
    maxProcesses = $MAX_PROCS,
    insist = true
}

sync {
    default.rsync,
    source = "$SOURCE_DIR",
    target = "$SYNC_TARGET",
    exclude = { "*/node_modules/*" },
    rsync = {
        binary = "$RSYNC_WRAPPER",
        archive = true,
        hard_links = true,
        acls = true,
        xattrs = true,
        numeric_ids = true,
        compress = false,
        perms = true,
        owner = true,
        group = true,
        _extra = { "--delete" }
    }
}
EOF

# ==============================================================================
# Systemd Services & Timers
# ==============================================================================
log "Installing Systemd Timers (Watchdog & Retention)..."

# Watchdog Service & Timer (Every 1 Minute)
cat << 'EOF' > /etc/systemd/system/ptero-watchdog.service
[Unit]
Description=Pterodactyl NAS Sync Watchdog
[Service]
Type=oneshot
ExecStart=/usr/local/bin/pterodactyl-sync-watchdog.sh
EOF

cat << 'EOF' > /etc/systemd/system/ptero-watchdog.timer
[Unit]
Description=Run Pterodactyl NAS Sync Watchdog every minute
[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
[Install]
WantedBy=timers.target
EOF

# Retention Service & Timer (Daily)
cat << 'EOF' > /etc/systemd/system/ptero-retention.service
[Unit]
Description=Pterodactyl NAS Sync Retention Cleanup
[Service]
Type=oneshot
ExecStart=/usr/local/bin/pterodactyl-sync-retention.sh
EOF

cat << 'EOF' > /etc/systemd/system/ptero-retention.timer
[Unit]
Description=Run Pterodactyl NAS Sync Retention daily
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
EOF

# ==============================================================================
# Log Rotation
# ==============================================================================
cat << EOF > /etc/logrotate.d/pterodactyl-sync
$LSYNCD_LOG $WATCHDOG_LOG $LOG_FILE {
    size 1G
    rotate 3
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF

# ==============================================================================
# Final Validation & Boot Recovery Setup
# ==============================================================================
systemctl daemon-reload

# Disable default lsyncd startup. Watchdog handles it based on NAS health.
systemctl disable lsyncd >/dev/null 2>&1
systemctl stop lsyncd >/dev/null 2>&1

systemctl enable --now ptero-watchdog.timer >/dev/null 2>&1
systemctl enable --now ptero-retention.timer >/dev/null 2>&1

# Run watchdog once to evaluate and start lsyncd
/usr/local/bin/pterodactyl-sync-watchdog.sh

echo -e "\n${GREEN}====================================================${NC}"
echo -e "${GREEN} Installation Complete!${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "Lsyncd is now managed automatically by the watchdog."
echo -e "If the NAS disconnects, sync pauses. When it returns, it resumes."
echo -e "Deleted files are moved to: ${CYAN}$SYNC_TARGET/deleted/YYYY/MM/DD${NC}"
echo -e "Root login notifications will alert you of failures."
echo -e "\nMaintenance Commands:"
echo -e "  ./install-pterodactyl-nas-sync.sh --status"
echo -e "  ./install-pterodactyl-nas-sync.sh --repair"
echo -e "  ./install-pterodactyl-nas-sync.sh --uninstall\n"
exit 0
