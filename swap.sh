#!/bin/bash

# Script to configure swap space on Ubuntu Server
# Created by Blackbox Assistant

# Function to display information messages
info() {
    echo -e "\e[1;34m[INFO]\e[0m $1"
}

# Function to display success messages
success() {
    echo -e "\e[1;32m[SUCCESS]\e[0m $1"
}

# Function to display error messages
error() {
    echo -e "\e[1;31m[ERROR]\e[0m $1"
    exit 1
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root. Please use sudo."
fi

# Clear screen
clear

echo "===================================="
echo "    Ubuntu Server Swap Creator      "
echo "===================================="
echo ""

# Ask for swap size
read -p "Enter the amount of swap (e.g., 2G, 4096M): " SWAP_SIZE
if [ -z "$SWAP_SIZE" ]; then
    error "Swap size cannot be empty."
fi

# Validate swap size format
if ! [[ "$SWAP_SIZE" =~ ^[0-9]+[GM]$ ]]; then
    error "Invalid swap size format. Please use format like 2G or 4096M."
fi

# Ask if permanent or temporary
while true; do
    read -p "Make swap permanent? (y/n): " PERMANENT
    case $PERMANENT in
        [Yy]* ) PERMANENT=true; break;;
        [Nn]* ) PERMANENT=false; break;;
        * ) echo "Please answer yes (y) or no (n).";;
    esac
done

# Ask for swap file location
read -p "Enter swap file location [default: /swapfile]: " SWAP_FILE
SWAP_FILE=${SWAP_FILE:-/swapfile}

# Check if swap file already exists
if [ -f "$SWAP_FILE" ]; then
    read -p "Swap file $SWAP_FILE already exists. Replace it? (y/n): " REPLACE
    if [[ $REPLACE =~ ^[Yy]$ ]]; then
        info "Removing existing swap file..."
        swapoff "$SWAP_FILE" 2>/dev/null
        rm -f "$SWAP_FILE"
    else
        error "Operation cancelled."
    fi
fi

# Ask for swappiness
read -p "Enter swappiness value (0-100) [default: 50]: " SWAPPINESS
SWAPPINESS=${SWAPPINESS:-50}

# Validate swappiness
if ! [[ "$SWAPPINESS" =~ ^[0-9]+$ ]] || [ "$SWAPPINESS" -lt 0 ] || [ "$SWAPPINESS" -gt 100 ]; then
    error "Invalid swappiness value. It must be between 0 and 100."
fi

# Display configuration summary
echo ""
echo "Swap Configuration Summary:"
echo "--------------------------"
echo "Swap Size: $SWAP_SIZE"
echo "Permanent: $([ "$PERMANENT" = true ] && echo "Yes" || echo "No")"
echo "Swap File: $SWAP_FILE"
echo "Swappiness: $SWAPPINESS"
echo ""

# Confirm before proceeding
read -p "Proceed with this configuration? (y/n): " CONFIRM
if ! [[ $CONFIRM =~ ^[Yy]$ ]]; then
    error "Operation cancelled by user."
fi

# Create swap file
info "Creating swap file ($SWAP_SIZE)..."
if [[ "$SWAP_SIZE" =~ G$ ]]; then
    # Size in GB, convert to count for fallocate
    SIZE_NUM=${SWAP_SIZE%G}
    fallocate -l "${SIZE_NUM}G" "$SWAP_FILE" || dd if=/dev/zero of="$SWAP_FILE" bs=1G count="$SIZE_NUM"
else
    # Size in MB, convert to count for fallocate
    SIZE_NUM=${SWAP_SIZE%M}
    fallocate -l "${SIZE_NUM}M" "$SWAP_FILE" || dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SIZE_NUM"
fi

# Set permissions
chmod 600 "$SWAP_FILE"

# Format as swap
info "Formatting swap file..."
mkswap "$SWAP_FILE"

# Enable swap
info "Enabling swap..."
swapon "$SWAP_FILE"

# Configure permanent swap if requested
if [ "$PERMANENT" = true ]; then
    info "Setting up permanent swap..."
    if ! grep -q "$SWAP_FILE" /etc/fstab; then
        echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    else
        info "Swap entry already exists in fstab. No changes made."
    fi
fi

# Set swappiness
info "Setting swappiness to $SWAPPINESS..."
sysctl -w vm.swappiness="$SWAPPINESS"

# Make swappiness permanent
if [ "$PERMANENT" = true ]; then
    if ! grep -q "vm.swappiness" /etc/sysctl.conf; then
        echo "vm.swappiness=$SWAPPINESS" >> /etc/sysctl.conf
    else
        sed -i "s/vm.swappiness=.*/vm.swappiness=$SWAPPINESS/" /etc/sysctl.conf
    fi
fi

# Show current swap status
echo ""
success "Swap configuration completed successfully!"
echo ""
echo "Current Swap Status:"
echo "------------------"
swapon --show
echo ""
free -h
echo ""

if [ "$PERMANENT" = true ]; then
    success "Swap has been permanently configured and will persist after reboot."
else
    info "Swap is temporary and will not persist after reboot."
fi
