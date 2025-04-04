#!/bin/bash
# Interactive Tailscale Setup Script
# Asks for all details during runtime

echo -e "\033[1;36m=== Tailscale Auto-Setup ===\033[0m"
echo "This script will:"
echo "1) Install Tailscale"
echo "2) Configure as either VPS or Home Server"
echo "3) Set up port forwarding (if VPS)"
echo ""

# Ask for setup type
PS3="Choose setup type: "
select OPTION in "VPS (port forwarder)" "Home Server (receive traffic)"; do
  case $OPTION in
    "VPS (port forwarder)")
      SETUP_TYPE="vps"
      break
      ;;
    "Home Server (receive traffic)")
      SETUP_TYPE="home"
      break
      ;;
    *) echo "Invalid option";;
  esac
done

# Get common details
read -p "Enter Tailscale hostname for this device: " TAILSCALE_HOSTNAME
read -p "Enter your Tailscale auth key (or press Enter to use browser auth): " TAILSCALE_AUTHKEY

if [ -z "$TAILSCALE_AUTHKEY" ]; then
  AUTH_METHOD="--hostname=$TAILSCALE_HOSTNAME"
else
  AUTH_METHOD="--authkey=$TAILSCALE_AUTHKEY --hostname=$TAILSCALE_HOSTNAME"
fi

# Install Tailscale (both options)
echo -e "\n\033[1;33mInstalling Tailscale...\033[0m"
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up $AUTH_METHOD
TAILSCALE_IP=$(tailscale ip -4)
echo -e "\033[1;32m✓ Connected to Tailscale as $TAILSCALE_HOSTNAME ($TAILSCALE_IP)\033[0m"

# VPS Setup
if [ "$SETUP_TYPE" = "vps" ]; then
  read -p "Enter home server's Tailscale IP: " HOME_SERVER_IP
  read -p "Enter ports to forward (space separated, e.g., '22 80 443 8500-8700'): " PORTS_TO_FORWARD
  
  echo -e "\n\033[1;33mConfiguring VPS port forwarding...\033[0m"
  sudo bash -c "echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf"
  sudo sysctl -p
  
  # Process ports/ranges
  for ENTRY in $PORTS_TO_FORWARD; do
    if [[ $ENTRY == *"-"* ]]; then
      START=${ENTRY%-*}
      END=${ENTRY#*-}
      for (( PORT=START; PORT<=END; PORT++ )); do
        sudo iptables -t nat -A PREROUTING -p tcp --dport $PORT -j DNAT --to-destination $HOME_SERVER_IP:$PORT
        sudo iptables -t nat -A PREROUTING -p udp --dport $PORT -j DNAT --to-destination $HOME_SERVER_IP:$PORT
        echo "Forwarded port $PORT (TCP/UDP)"
      done
    else
      sudo iptables -t nat -A PREROUTING -p tcp --dport $ENTRY -j DNAT --to-destination $HOME_SERVER_IP:$ENTRY
      sudo iptables -t nat -A PREROUTING -p udp --dport $ENTRY -j DNAT --to-destination $HOME_SERVER_IP:$ENTRY
      echo "Forwarded port $ENTRY (TCP/UDP)"
    fi
  done
  
  sudo iptables -A FORWARD -i eth0 -o tailscale0 -j ACCEPT
  sudo iptables -A FORWARD -i tailscale0 -o eth0 -j ACCEPT
  sudo iptables -t nat -A POSTROUTING -o tailscale0 -j MASQUERADE
  
  sudo apt-get install -y iptables-persistent
  sudo netfilter-persistent save
  
  echo -e "\033[1;32m✓ VPS setup complete! Forwarding ports to $HOME_SERVER_IP\033[0m"

# Home Server Setup
else
  echo -e "\n\033[1;33mConfiguring Home Server...\033[0m"
  sudo systemctl stop ufw 2>/dev/null
  sudo systemctl disable ufw 2>/dev/null
  
  # Create persistent IP assignment
  sudo tee /etc/systemd/system/tailscale-persist.service > /dev/null <<EOF
[Unit]
Description=Persistent Tailscale IP
After=tailscale.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c "until ip addr show tailscale0 | grep -q $TAILSCALE_IP; do sleep 1; done"
ExecStart=/sbin/ip addr add $TAILSCALE_IP/32 dev tailscale0

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl enable --now tailscale-persist.service
  echo -e "\033[1;32m✓ Home server ready! Using Tailscale IP $TAILSCALE_IP\033[0m"
fi

echo -e "\n\033[1;35mSetup Summary:\033[0m"
echo "Device Name: $TAILSCALE_HOSTNAME"
echo "Tailscale IP: $TAILSCALE_IP"
[ "$SETUP_TYPE" = "vps" ] && echo "Forwarding Ports: $PORTS_TO_FORWARD to $HOME_SERVER_IP"
echo -e "\nRun 'tailscale status' to verify connections"
