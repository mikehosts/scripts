#!/usr/bin/env bash
# ==============================================================================
# Pterodactyl -> NAS Real-Time Parallel Sync Enterprise Installer
# ==============================================================================
# Priority: Parallel Engine | Real-time | Auto-recovery | Scale | Deployment Ease
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
    echo -e "${YELLOW}Uninstalling Pterodactyl Parallel Sync...${NC}"
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
# Pre-flight Checks & Installation (Includes fpart/fpsync)
# ==============================================================================
if [[ $EUID -ne 0 ]]; then err "This script must be run as root."; fi

log "Installing dependencies (rsync, cifs-utils, lsyncd, jq, bc, fpart)..."
apt-get update -qq && apt-get install -y -qq rsync cifs-utils lsyncd jq bc acl attr fpart

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

# Create Credentials File Safely
cat << EOF > "$CRED_FILE"
username=${NAS_USER}
password=${NAS_PASS}
EOF
chmod 600 "$CRED_FILE"

# ==============================================================================
# Auto-Detect SMB Version & Mount (Speed Optimized)
# ==============================================================================
log "Negotiating SMB version with $NAS_HOST..."
mkdir -p "$NAS_MOUNT"
SMB_VERSION=""

# Performance Flags: Max out buffer windows to 1MB; loose metadata caching to avoid SMB round-trips
MOUNT_OPTS="credentials=$CRED_FILE,iocharset=utf8,noperm,rsize=1048576,wsize=1048576,cache=loose"

for v in 3.1.1 3.0 2.1; do
    if mount -t cifs -o vers=$v,$MOUNT_OPTS "//$NAS_HOST/$NAS_SHARE" "$NAS_MOUNT" 2>/dev/null; then
        SMB_VERSION=$v
        log "Successfully connected using SMB $SMB_VERSION (Speed Optimized)"
        break
    fi
done

if [[ -z "$SMB_VERSION" ]]; then err "Failed to connect to NAS. Check IP, Share, and Credentials."; fi

# Verify Writable
if ! touch "$NAS_MOUNT/.test_write" 2>/dev/null; then err "NAS is mounted but not writable."; fi
rm -f "$NAS_MOUNT/.test_write"

# Fstab configuration
sed -i '\#ptero_nas#d' /etc/fstab
echo "//$NAS_HOST/$NAS_SHARE $NAS_MOUNT cifs vers=$SMB_VERSION,$MOUNT_OPTS 0 0" >> /etc/fstab

# Setup Sync Target Directory
NAS_FOLDER=$(echo "$NAS_FOLDER" | sed -e 's/^\/*//' -e 's/\/*$//')
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
# Analysis Phase & ETA Calculation
# ==============================================================================
log "Analyzing source data (Skipping junk paths)..."

set +e
FILE_COUNT=$(find "$SOURCE_DIR" -type f ! -path "*/node_modules/*" ! -path "*/.cache/*" ! -path "*/.tmp/*" 2>/dev/null | wc -l)
DIR_COUNT=$(find "$SOURCE_DIR" -type d ! -path "*/node_modules/*" ! -path "*/.cache/*" ! -path "*/.tmp/*" 2>/dev/null | wc -l)
SOURCE_KB=$(du -sk --exclude="*/node_modules/*" --exclude="*/.cache/*" --exclude="*/.tmp/*" "$SOURCE_DIR" 2>/dev/null | cut -f1)
set -e

SOURCE_KB=${SOURCE_KB:-1}
SOURCE_GB=$(echo "scale=2; $SOURCE_KB / 1024 / 1024" | bc)
NAS_KB_FREE=$(df -P "$NAS_MOUNT" | awk 'NR==2 {print $4}')
NAS_GB_FREE=$(echo "scale=2; $NAS_KB_FREE / 1024 / 1024" | bc)

# Multi-threaded target speed projection up to ~110 MB/s (112640 KB/s) on配置
EST_SEC=$(( SOURCE_KB / 112640 ))
EST_HOURS=$(( EST_SEC / 3600 ))
EST_MIN=$(( (EST_SEC % 3600) / 60 ))

echo -e "\n${CYAN}--- Initial Analysis (Exclusions Applied) ---${NC}"
echo -e "Files:       $FILE_COUNT"
echo -e "Directories: $DIR_COUNT"
echo -e "Size:        ${SOURCE_GB} GB"
echo -e "NAS Free:    ${NAS_GB_FREE} GB"
echo -e "Est. Time:   ${YELLOW}${EST_HOURS}h ${EST_MIN}m${NC} (Assuming parallel multi-stream speed)"

if (( SOURCE_KB > NAS_KB_FREE )); then
    warn "NAS FREE SPACE IS LESS THAN SOURCE SIZE!"
    read -p "Continue anyway? (y/n): " space_cont
    if [[ "$space_cont" != "y" ]]; then exit 1; fi
fi

# ==============================================================================
# CPU Concurrency Tuning
# ==============================================================================
log "Tuning System Concurrency Options..."
THREADS=$(nproc)
LOAD=$(awk '{print $1}' /proc/loadavg)
LOAD_PCT=$(echo "scale=2; ($LOAD / $THREADS) * 100" | bc | cut -d. -f1)
REC_THREADS=$(echo "scale=0; $THREADS * 0.7 / 1" | bc)
[[ $REC_THREADS -lt 2 ]] && REC_THREADS=2

echo -e "\nDetected Threads: $THREADS"
echo -e "Current CPU Usage: ${LOAD_PCT}%"

MAX_PROCS=$REC_THREADS
echo "1) Balanced Parallel Mode ($REC_THREADS concurrent workers)"
echo "2) Maximum Performance Engine ($THREADS concurrent workers)"
echo "3) Custom Concurrency Level"
read -p "Select parallel worker profile [1]: " cpu_choice
case ${cpu_choice:-1} in
    2) MAX_PROCS=$THREADS ;;
    3) read -p "Enter number of custom execution streams: " MAX_PROCS ;;
    *) MAX_PROCS=$REC_THREADS ;;
esac

# Host Memory Optimization Configuration
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
# Initial Sync Execution (Parallel Mode via fpsync)
# ==============================================================================
echo -e "\n${CYAN}--- Initial Parallel Sync Execution ---${NC}"
read -p "Execute multi-threaded initialization now? (y/n): " run_sync
if [[ "$run_sync" == "y" ]]; then
    
    log "Launching Parallel Engine with $MAX_PROCS execution channels..."
    log "Exclusions active: node_modules, .cache, and .tmp are skipped."
    
    while true; do
        if mountpoint -q "$NAS_MOUNT" && touch "$NAS_MOUNT/.write_test" 2>/dev/null; then
            rm -f "$NAS_MOUNT/.write_test"
            set +e
            
            # Run fpsync using the selected thread count
            fpsync -n "$MAX_PROCS" -v \
                -o "-aHAX --numeric-ids --exclude='*/node_modules/*' --exclude='*/.cache/*' --exclude='*/.tmp/*'" \
                "$SOURCE_DIR/" "$SYNC_TARGET/"
            
            SYNC_EXIT=$?
            set -e
            
            if [[ $SYNC_EXIT -eq 0 ]]; then
                log "Initial parallel file synchronization completed successfully."
                break
            else
                warn "Parallel synchronizer flagged interruptions (code $SYNC_EXIT). Retrying batch cycle in 15 seconds..."
                sleep 15
            fi
        else
            warn "NAS target dropped offline. Reinitializing mount parameters..."
            umount -l "$NAS_MOUNT" 2>/dev/null || true
            mount "$NAS_MOUNT" 2>/dev/null || true
            sleep 10
        fi
    done
fi

# ==============================================================================
# Runtime Component & Background Scripts Generation
# ==============================================================================
log "Generating real-time automation frameworks..."

# 1. Real-time Rsync Worker Wrapper
cat << EOF > "$RSYNC_WRAPPER"
#!/bin/bash
TODAY=\$(date +%Y/%m/%d)
BACKUP_DIR="$SYNC_TARGET/deleted/\$TODAY"
mkdir -p "\$BACKUP_DIR"
exec /usr/bin/rsync --backup --backup-dir="\$BACKUP_DIR" "\$@"
EOF
chmod +x "$RSYNC_WRAPPER"

# 2. Storage System Watchdog Script
cat << EOF > "$WATCHDOG_SCRIPT"
#!/bin/bash
MOUNT_POINT="$NAS_MOUNT"
ALERT_FILE="$PROFILE_ALERT"
ERROR=0
REASON=""

if ! mountpoint -q "\$MOUNT_POINT"; then
    mount "\$MOUNT_POINT" || { ERROR=1; REASON="NAS Connection Dropped / Mount Offline"; }
fi

if [[ \$ERROR -eq 0 ]] && ! touch "\$MOUNT_POINT/.watchdog" 2>/dev/null; then
    ERROR=1; REASON="NAS target transitioned to Read-Only";
fi
rm -f "\$MOUNT_POINT/.watchdog" 2>/dev/null

if [[ \$ERROR -eq 0 ]]; then
    FREE_KB=\$(df -P "\$MOUNT_POINT" | awk 'NR==2 {print \$4}')
    if (( FREE_KB < 1048576 )); then ERROR=1; REASON="Critical Low Space Alert (< 1GB Remaining)"; fi
fi

if [[ \$ERROR -eq 1 ]]; then
    systemctl stop lsyncd 2>/dev/null
    echo -e "echo -e '\\033[0;31m[CRITICAL] Pterodactyl Parallel Sync Fault: '\$REASON'\\033[0m'" > "\$ALERT_FILE"
    echo "\$(date): Recovery Failure - \$REASON" >> "$WATCHDOG_LOG"
else
    rm -f "\$ALERT_FILE"
    if ! systemctl is-active --quiet lsyncd; then
        systemctl start lsyncd
        echo "\$(date): Storage verification healthy. Engine started." >> "$WATCHDOG_LOG"
    fi
fi
EOF
chmod +x "$WATCHDOG_SCRIPT"

# 3. Storage Retention Maintenance Engine
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
# Lsyncd Production Daemon Setup
# ==============================================================================
log "Configuring production real-time sync mapping rules..."
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
    exclude = { "*/node_modules/*", "*/.cache/*", "*/.tmp/*" },
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
# Automation Control Loop Integration (Systemd Engine)
# ==============================================================================
log "Finalizing background runtime architectures..."

cat << 'EOF' > /etc/systemd/system/ptero-watchdog.service
[Unit]
Description=Pterodactyl NAS Sync Monitor Daemon
[Service]
Type=oneshot
ExecStart=/usr/local/bin/pterodactyl-sync-watchdog.sh
EOF

cat << 'EOF' > /etc/systemd/system/ptero-watchdog.timer
[Unit]
Description=Trigger Pterodactyl Storage Watchdog Check Loop
[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
[Install]
WantedBy=timers.target
EOF

cat << 'EOF' > /etc/systemd/system/ptero-retention.service
[Unit]
Description=Pterodactyl Storage Retention Garbage Collector
[Service]
Type=oneshot
ExecStart=/usr/local/bin/pterodactyl-sync-retention.sh
EOF

cat << 'EOF' > /etc/systemd/system/ptero-retention.timer
[Unit]
Description=Trigger Pterodactyl Storage Retention Engine Daily
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
EOF

# System Log Rotation Setup
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
# Initialization & Handover Execution
# ==============================================================================
systemctl daemon-reload
systemctl disable lsyncd >/dev/null 2>&1
systemctl stop lsyncd >/dev/null 2>&1
systemctl enable --now ptero-watchdog.timer >/dev/null 2>&1
systemctl enable --now ptero-retention.timer >/dev/null 2>&1

# Initialize state health validation run
/usr/local/bin/pterodactyl-sync-watchdog.sh

echo -e "\n${GREEN}====================================================${NC}"
echo -e "${GREEN} Parallel Sync Deployment Success!${NC}"
echo -e "${GREEN}====================================================${NC}"
exit 0
