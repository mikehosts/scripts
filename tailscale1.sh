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
      echo -e "\n${GREEN}Exiting...${NC}"
      exit 0
      ;;
    *)
      echo -e "\n${RED}Invalid option!${NC}" >&2
      read -p "Press Enter to continue..."
      ;;
  esac
done
