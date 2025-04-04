#!/bin/bash
# Ultimate Tailscale Setup Script
# Features:
# 1. Interactive VPS or Home Server setup
# 2. Automatic crontab fallback if systemd fails
# 3. Port forwarding with range support
# 4. Persistent configuration

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to setup persistent IP with fallback
setup_persistent_ip() {
    local TS_IP=$(tailscale ip -4)
    local INTERFACE="tailscale0"
    
    echo -e "${YELLOW}🛠 Setting up persistent IP $TS_IP...${NC}"
    
    # Try systemd service first
    echo -e "${BLUE}Attempting systemd service...${NC}"
    sudo tee /etc/systemd/system/tailscale-persist.service > /dev/null <<EOF
[Unit]
Description=Persistent Tailscale IP
After=network.target tailscale.service
Requires=tailscale.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 5
ExecStart=/bin/sh -c "ip addr add $TS_IP/32 dev $INTERFACE || true"
ExecStop=/bin/sh -c "ip addr del $TS_IP/32 dev $INTERFACE || true"

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now tailscale-persist.service >/dev/null 2>&1
    
    # Verify systemd
    if ! systemctl is-active --quiet tailscale-persist.service; then
        echo -e "${RED}❌ Systemd service failed, installing crontab fallback...${NC}"
        (crontab -l 2>/dev/null | grep -v "$INTERFACE"; 
         echo "@reboot sleep 10 && /sbin/ip addr add $TS_IP/32 dev $INTERFACE") | crontab -
        echo -e "${GREEN}✓ Crontab fallback installed${NC}"
    else
        echo -e "${GREEN}✓ Systemd service active${NC}"
    fi
    
    # Apply immediately
    sudo ip addr add $TS_IP/32 dev $INTERFACE 2>/dev/null || true
}

# Main script
echo -e "${BLUE}=== Tailscale Auto-Setup ===${NC}"
echo "1) VPS (port forwarder)"
echo "2) Home Server (receive traffic)"
read -p "Choose option (1 or 2): " SETUP_TYPE

# Get common details
read -p "Enter Tailscale hostname for this device: " TAILSCALE_HOSTNAME
read -p "Enter your Tailscale auth key (or press Enter for browser auth): " TAILSCALE_AUTHKEY

# Install Tailscale
echo -e "${YELLOW}Installing Tailscale...${NC}"
curl -fsSL https://tailscale.com/install.sh | sh

if [ -z "$TAILSCALE_AUTHKEY" ]; then
    sudo tailscale up --hostname="$TAILSCALE_HOSTNAME"
else
    sudo tailscale up --authkey="$TAILSCALE_AUTHKEY" --hostname="$TAILSCALE_HOSTNAME"
fi

TAILSCALE_IP=$(tailscale ip -4)
echo -e "${GREEN}✓ Connected as $TAILSCALE_HOSTNAME ($TAILSCALE_IP)${NC}"

# VPS Setup
if [ "$SETUP_TYPE" == "1" ]; then
    read -p "Enter home server's Tailscale IP: " HOME_SERVER_IP
    read -p "Enter ports to forward (space separated, e.g., '22 80 8500-8700'): " PORTS_TO_FORWARD
    
    echo -e "${YELLOW}Configuring VPS port forwarding...${NC}"
    sudo bash -c "echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf"
    sudo sysctl -p
    
    # Process ports
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
    
    echo -e "${GREEN}✓ VPS setup complete! Forwarding to $HOME_SERVER_IP${NC}"

# Home Server Setup
else
    echo -e "${YELLOW}Configuring Home Server...${NC}"
    sudo systemctl stop ufw 2>/dev/null
    sudo systemctl disable ufw 2>/dev/null
    
    setup_persistent_ip
    
    echo -e "${GREEN}✓ Home server ready! Using IP $TAILSCALE_IP${NC}"
fi

echo -e "\n${BLUE}=== Setup Summary ===${NC}"
echo "Device Name: $TAILSCALE_HOSTNAME"
echo "Tailscale IP: $TAILSCALE_IP"
[ "$SETUP_TYPE" == "1" ] && echo "Forwarding Ports: $PORTS_TO_FORWARD to $HOME_SERVER_IP"
echo -e "\nRun these commands to verify:"
echo "tailscale status"
echo "ip addr show tailscale0"
[ "$SETUP_TYPE" == "1" ] && echo "sudo iptables -t nat -L -n"
