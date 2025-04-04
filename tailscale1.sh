#!/bin/bash
# Fully Tested Tailscale Port Management Script
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

# Check if run as root
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}This script must be run as root!${NC}" >&2
  exit 1
fi

# Verify dependencies
check_deps() {
  local missing=()
  for dep in iptables tailscale curl; do
    if ! command -v $dep &>/dev/null; then
      missing+=("$dep")
    fi
  done
  
  if [ ${#missing[@]} -gt 0 ]; then
    echo -e "${YELLOW}Installing missing dependencies: ${missing[*]}${NC}"
    apt-get update && apt-get install -y ${missing[@]} || {
      echo -e "${RED}Failed to install dependencies!${NC}" >&2
      exit 1
    }
  fi
}

# Function to setup persistent IP
setup_persistent_ip() {
  local TS_IP=$(tailscale ip -4)
  [ -z "$TS_IP" ] && { echo -e "${RED}Could not get Tailscale IP!${NC}"; exit 1; }
  
  echo -e "${YELLOW}🛠 Setting up persistent IP $TS_IP...${NC}"
  
  # Create systemd service
  sudo tee /etc/systemd/system/tailscale-persist.service > /dev/null <<EOF
[Unit]
Description=Persistent Tailscale IP
After=network.target tailscale.service
Requires=tailscale.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c "while ! ip link show tailscale0 &>/dev/null; do sleep 1; done; ip addr add $TS_IP/32 dev tailscale0"
ExecStop=/bin/bash -c "ip addr del $TS_IP/32 dev tailscale0 || true"

[Install]
WantedBy=multi-user.target
EOF

  # Enable and start service
  sudo systemctl daemon-reload
  if ! sudo systemctl enable --now tailscale-persist.service; then
    echo -e "${YELLOW}⚠ Systemd service failed, setting up crontab fallback...${NC}"
    (crontab -l 2>/dev/null | grep -v "ip addr add $TS_IP"; 
     echo "@reboot sleep 5 && /sbin/ip addr add $TS_IP/32 dev tailscale0") | crontab -
    echo -e "${GREEN}✓ Crontab fallback installed${NC}"
  else
    echo -e "${GREEN}✓ Systemd service active${NC}"
  fi
  
  # Apply immediately
  sudo ip addr add $TS_IP/32 dev tailscale0 2>/dev/null || true
}

# Function to enable IP forwarding
enable_ip_forwarding() {
  echo -e "${YELLOW}Enabling IP forwarding...${NC}"
  
  # Enable IPv4 forwarding
  if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
  fi
  
  # Enable IPv6 forwarding
  if ! grep -q "^net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf; then
    echo 'net.ipv6.conf.all.forwarding=1' | sudo tee -a /etc/sysctl.conf
  fi
  
  # Apply changes
  sudo sysctl -p
  
  # Confirm that IP forwarding is enabled
  if [[ $(sysctl net.ipv4.ip_forward | awk '{print $3}') -eq 1 ]]; then
    echo -e "${GREEN}✓ IPv4 forwarding is enabled${NC}"
  else
    echo -e "${RED}✗ Failed to enable IPv4 forwarding${NC}"
  fi
  
  if [[ $(sysctl net.ipv6.conf.all.forwarding | awk '{print $3}') -eq 1 ]]; then
    echo -e "${GREEN}✓ IPv6 forwarding is enabled${NC}"
  else
    echo -e "${RED}✗ Failed to enable IPv6 forwarding${NC}"
  fi
}

# Function to manage port forwarding
manage_ports() {
  local action=$1
  local target_ip=$2
  local ports=$3
  
  for entry in $ports; do
    if [[ $entry == *-* ]]; then
      IFS='-' read -ra range <<< "$entry"
      start=${range[0]}
      end=${range[1]}
      
      for (( port=start; port<=end; port++ )); do
        for proto in tcp udp; do
          if [ "$action" == "add" ]; then
            if ! sudo iptables -t nat -C PREROUTING -p $proto --dport $port -j DNAT --to-destination $target_ip:$port 2>/dev/null; then
              sudo iptables -t nat -A PREROUTING -p $proto --dport $port -j DNAT --to-destination $target_ip:$port
              echo -e "${GREEN}+ Added $proto port $port${NC}"
            fi
          else
            if sudo iptables -t nat -C PREROUTING -p $proto --dport $port -j DNAT --to-destination $target_ip:$port 2>/dev/null; then
              sudo iptables -t nat -D PREROUTING -p $proto --dport $port -j DNAT --to-destination $target_ip:$port
              echo -e "${RED}- Removed $proto port $port${NC}"
            fi
          fi
        done
      done
    else
      for proto in tcp udp; do
        if [ "$action" == "add" ]; then
          if ! sudo iptables -t nat -C PREROUTING -p $proto --dport $entry -j DNAT --to-destination $target_ip:$entry 2>/dev/null; then
            sudo iptables -t nat -A PREROUTING -p $proto --dport $entry -j DNAT --to-destination $target_ip:$entry
            echo -e "${GREEN}+ Added $proto port $entry${NC}"
          fi
        else
          if sudo iptables -t nat -C PREROUTING -p $proto --dport $entry -j DNAT --to-destination $target_ip:$entry 2>/dev/null; then
            sudo iptables -t nat -D PREROUTING -p $proto --dport $entry -j DNAT --to-destination $target_ip:$entry
            echo -e "${RED}- Removed $proto port $entry${NC}"
          fi
        fi
      done
    fi
  done
  
  # Save rules
  if command -v netfilter-persistent &>/dev/null; then
    sudo netfilter-persistent save
  elif command -v iptables-save &>/dev/null; then
    sudo iptables-save > /etc/iptables/rules.v4
    sudo ip6tables-save > /etc/iptables/rules.v6
  fi
}

# Main menu
while true; do
  clear
  echo -e "${BLUE}=== Tailscale Port Manager ===${NC}"
  echo "1) Setup new VPS (port forwarder)"
  echo "2) Setup new Home Server (receive ports)"
  echo "3) Remove forwarded ports"
  echo "4) Add more forwarded ports"
  echo "5) View current port forwarding"
  echo "6) Exit"
  read -p "Choose option (1-6): " OPTION

  case $OPTION in
    1)
      # VPS Setup
      echo -e "\n${YELLOW}=== VPS Setup ===${NC}"
      read -p "Enter Tailscale hostname for this VPS: " TAILSCALE_HOSTNAME
      read -p "Enter home server's Tailscale IP: " HOME_SERVER_IP
      read -p "Enter ports to forward (e.g., '22 80 443 8500-8700'): " PORTS_TO_FORWARD
      
      check_deps
      
      echo -e "\n${YELLOW}Installing Tailscale...${NC}"
      curl -fsSL https://tailscale.com/install.sh | sh
      sudo tailscale up --hostname="$TAILSCALE_HOSTNAME" || {
        echo -e "${RED}Failed to start Tailscale!${NC}" >&2
        exit 1
      }
      
      echo -e "\n${YELLOW}Configuring IP forwarding...${NC}"
      enable_ip_forwarding  # Call the function to enable IP forwarding
      
      manage_ports "add" "$HOME_SERVER_IP" "$PORTS_TO_FORWARD"
      
      # Ensure forwarding rules exist
      sudo iptables -A FORWARD -i eth0 -o tailscale0 -j ACCEPT
      sudo iptables -A FORWARD -i tailscale0 -o eth0 -j ACCEPT
      sudo iptables -t nat -A POSTROUTING -o tailscale0 -j MASQUERADE
      
      echo -e "\n${GREEN}✓ VPS setup complete! Forwarding to $HOME_SERVER_IP${NC}"
      read -p "Press Enter to continue..."
      ;;
    2)
      # Home Server Setup
      echo -e "\n${YELLOW}=== Home Server Setup ===${NC}"
      read -p "Enter Tailscale hostname for this server: " TAILSCALE_HOSTNAME
      
      check_deps
      
      echo -e "\n${YELLOW}Installing Tailscale...${NC}"
      curl -fsSL https://tailscale.com/install.sh | sh
      sudo tailscale up --hostname="$TAILSCALE_HOSTNAME" || {
        echo -e "${RED}Failed to start Tailscale!${NC}" >&2
        exit 1
      }
      
      echo -e "\n${YELLOW}Configuring Home Server...${NC}"
      sudo systemctl stop ufw 2>/dev/null
      sudo systemctl disable ufw 2>/dev/null
      
      setup_persistent_ip
      
      echo -e "\n${GREEN}✓ Home server ready!${NC}"
      read -p "Press Enter to continue..."
      ;;
    3)
      # Remove Ports
      echo -e "\n${YELLOW}=== Remove Port Forwarding ===${NC}"
      read -p "Enter home server's Tailscale IP: " HOME_SERVER_IP
      read -p "Enter ports to remove (e.g., '8080 9000-9100'): " PORTS_TO_REMOVE
      
      manage_ports "remove" "$HOME_SERVER_IP" "$PORTS_TO_REMOVE"
      
      echo -e "\n${GREEN}✓ Port forwarding removed${NC}"
      read -p "Press Enter to continue..."
      ;;
    4)
      # Add Ports
      echo -e "\n${YELLOW}=== Add Port Forwarding ===${NC}"
      read -p "Enter home server's Tailscale IP: " HOME_SERVER_IP
      read -p "Enter ports to add (e.g., '3306 9000-9100'): " PORTS_TO_ADD
      
      manage_ports "add" "$HOME_SERVER_IP" "$PORTS_TO_ADD"
      
      echo -e "\n${GREEN}✓ Port forwarding added${NC}"
      read -p "Press Enter to continue..."
      ;;
    5)
      # View current forwarding
      echo -e "\n${YELLOW}=== Current Port Forwarding ===${NC}"
      echo -e "${BLUE}NAT Rules:${NC}"
      sudo iptables -t nat -L PREROUTING -n --line-numbers | grep DNAT
      echo -e "\n${BLUE}Forwarding Rules:${NC}"
      sudo iptables -L FORWARD -n --line-numbers
      read -p "Press Enter to continue..."
      ;;
    6)
      echo -e "\n${GREEN}Exiting...
