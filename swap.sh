#!/bin/bash

# Ask user for swap size
read -p "Enter swap size in GB (e.g., 64): " SWAPSIZE

# Convert GB to bytes
SWAPFILE="/swapfile"
echo "Creating $SWAPSIZE GB swap at $SWAPFILE..."

# 1. Create swap file
sudo fallocate -l "${SWAPSIZE}G" $SWAPFILE
sudo chmod 600 $SWAPFILE
sudo mkswap $SWAPFILE
sudo swapon $SWAPFILE

# 2. Make swap permanent
echo "$SWAPFILE none swap sw 0 0" | sudo tee -a /etc/fstab

# 3. Set aggressive swap usage
sudo sysctl vm.swappiness=100
echo "vm.swappiness=100" | sudo tee -a /etc/sysctl.conf

# 4. Enable swap accounting for Docker
sudo sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 swapaccount=1"/' /etc/default/grub
sudo update-grub

# 5. Finish
echo "Swap of $SWAPSIZE GB created and swap accounting enabled."
echo "Rebooting is required to activate swap accounting..."
read -p "Press Enter to reboot now, or Ctrl+C to cancel."
sudo reboot
