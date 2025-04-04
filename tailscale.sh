#!/bin/bash
# Ultimate Tailscale Port Manager
# Options:
# 1) Setup VPS (port forwarder)
# 2) Setup Home Server (receive ports)
# 3) Remove forwarded ports
# 4) Add more forwarded ports

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
    
    if ! systemctl is-active --quiet tailscale-persist.service; then
        echo -e "${RED}❌ Systemd service failed, installing crontab fallback...${NC}"
        (crontab -l 2>/dev/null | grep -v "$INTERFACE"; 
         echo "@reboot sleep 10 && /sbin/ip addr add $TS_IP/32 dev $INTERFACE") | crontab -
        echo -e "${GREEN}✓ Crontab fallback installed${NC}"
    else
        echo -e "${GREEN}✓ Systemd service active${NC}"
    fi
    
    sudo ip addr add $TS_IP/32 dev $INTERFACE 2>/dev/null || true
}

# Function to forward ports
forward_ports() {
    local TARGET_IP=$1
    local PORTS=$2
    
    for ENTRY in $PORTS; do
        if [[ $ENTRY == *"-"* ]]; then
            START=${ENTRY%-*}
            END=${ENTRY#*-}
            for (( PORT=START; PORT<=END; PORT++ )); do
                sudo iptables -t nat -A PREROUTING -p tcp --dport $PORT -j DNAT --to-destination $TARGET_IP:$PORT
                sudo iptables -t nat -A PREROUTING -p udp --dport $PORT -j DNAT --to-destination $TARGET_IP:$PORT
                echo -e "${GREEN}+ Forwarded port $PORT (TCP/UDP)${NC}"
            done
        else
            sudo iptables -t nat -A PREROUTING -p tcp --dport $ENTRY -j DNAT --to-destination $TARGET_IP:$ENTRY
            sudo iptables -t nat -A PREROUTING -p udp --dport $ENTRY -j DNAT --to-destination $TARGET_IP:$ENTRY
            echo -e "${GREEN}+ Forwarded port $ENTRY (TCP/UDP)${NC}"
        fi
    done
    
    sudo netfilter-persistent save >/dev/null 2>&1
}

# Function to remove ports
remove_ports() {
    local TARGET_IP=$1
    local PORTS=$2
    
    for ENTRY in $PORTS; do
        if [[ $ENTRY == *"-"* ]]; then
            START=${ENTRY%-*}
            END=${ENTRY#*-}
            for (( PORT=START; PORT<=END; PORT++ )); do
                sudo iptables -t nat -D PREROUTING -p tcp --dport $PORT -j DNAT --to-destination $TARGET_IP:$PORT 2>/dev/null
                sudo iptables -t nat -D PREROUTING -p udp --dport $PORT -j DNAT --to-destination $TARGET_IP:$PORT 2>/dev/null
                echo -e "${RED}- Removed port $PORT forwarding${NC}"
            done
        else
            sudo iptables -t nat -D PREROUTING -p tcp --dport $ENTRY -j DNAT --to-destination $TARGET_IP:$ENTRY 2>/dev/null
            sudo iptables -t nat -D PREROUTING -p udp --dport $ENTRY -j DNAT --to-destination $TARGET_IP:$ENTRY 2>/dev/null
            echo -e "${RED}- Removed port $ENTRY forwarding${NC}"
        fi
    done
    
    sudo netfilter-persistent save >/dev/null 2>&1
}

# Main menu
echo -e "${BLUE}=== Tailscale Port Manager ===${NC}"
echo "1) Setup VPS (port forwarder)"
echo "2) Setup Home Server (receive ports)"
echo "3) Remove forwarded ports"
echo "4) Add more forwarded ports"
read -p "Choose option (1-4): " OPTION

case $OPTION in
    1)
        # VPS Setup
        read -p "Enter Tailscale hostname for this VPS: " TAILSCALE_HOSTNAME
        read -p "Enter home server's Tailscale IP: " HOME_SERVER_IP
        read -p "Enter ports to forward (e.g., '22 80 443 8500-8700'): " PORTS_TO_FORWARD
        
        echo -e "${YELLOW}Installing Tailscale...${NC}"
        curl -fsSL https://tailscale.com/install.sh | sh
        sudo tailscale up --hostname="$TAILSCALE_HOSTNAME"
        
        echo -e "${YELLOW}Configuring IP forwarding...${NC}"
        sudo bash -c "echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf"
        sudo sysctl -p
        
        forward_ports "$HOME_SERVER_IP" "$PORTS_TO_FORWARD"
        
        sudo iptables -A FORWARD -i eth0 -o tailscale0 -j ACCEPT
        sudo iptables -A FORWARD -i tailscale0 -o eth0 -j ACCEPT
        sudo iptables -t nat -A POSTROUTING -o tailscale0 -j MASQUERADE
        
        sudo apt-get install -y iptables-persistent
        sudo netfilter-persistent save
        
        echo -e "${GREEN}✓ VPS setup complete! Forwarding to $HOME_SERVER_IP${NC}"
        ;;
    2)
        # Home Server Setup
        read -p "Enter Tailscale hostname for this server: " TAILSCALE_HOSTNAME
        
        echo -e "${YELLOW}Installing Tailscale...${NC}"
        curl -fsSL https://tailscale.com/install.sh | sh
        sudo tailscale up --hostname="$TAILSCALE_HOSTNAME"
        
        echo -e "${YELLOW}Configuring Home Server...${NC}"
        sudo systemctl stop ufw 2>/dev/null
        sudo systemctl disable ufw 2>/dev/null
        
        setup_persistent_ip
        
        echo -e "${GREEN}✓ Home server ready!${NC}"
        ;;
    3)
        # Remove Ports
        read -p "Enter home server's Tailscale IP: " HOME_SERVER_IP
        read -p "Enter ports to remove (e.g., '8080 9000-9100'): " PORTS_TO_REMOVE
        
        remove_ports "$HOME_SERVER_IP" "$PORTS_TO_REMOVE"
        echo -e "${GREEN}✓ Port forwarding removed${NC}"
        ;;
    4)
        # Add Ports
        read -p "Enter home server's Tailscale IP: " HOME_SERVER_IP
        read -p "Enter ports to add (e.g., '3306 9000-9100'): " PORTS_TO_ADD
        
        forward_ports "$HOME_SERVER_IP" "$PORTS_TO_ADD"
        echo -e "${GREEN}✓ Port forwarding added${NC}"
        ;;
    *)
        echo -e "${RED}Invalid option${NC}"
        exit 1
        ;;
esac

echo -e "\n${BLUE}=== Current Port Forwarding ===${NC}"
sudo iptables -t nat -L PREROUTING -n | grep DNAT
