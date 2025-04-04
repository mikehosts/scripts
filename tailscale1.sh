#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root${NC}"
    exit 1
fi

# Function to install Tailscale
install_tailscale() {
    echo -e "${YELLOW}Installing Tailscale...${NC}"
    
    if command -v apt-get &> /dev/null; then
        # Debian/Ubuntu
        curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/focal.gpg | apt-key add -
        curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/focal.list | tee /etc/apt/sources.list.d/tailscale.list
        apt-get update
        apt-get install -y tailscale
    elif command -v yum &> /dev/null; then
        # RHEL/CentOS
        curl -fsSL https://pkgs.tailscale.com/stable/centos/7/tailscale.repo | tee /etc/yum.repos.d/tailscale.repo
        yum install -y tailscale
    elif command -v dnf &> /dev/null; then
        # Fedora
        dnf config-manager --add-repo https://pkgs.tailscale.com/stable/fedora/tailscale.repo
        dnf install -y tailscale
    else
        echo -e "${RED}Unsupported package manager. Please install Tailscale manually.${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Tailscale installed successfully${NC}"
}

# Function to authenticate Tailscale
auth_tailscale() {
    echo -e "${YELLOW}Authenticating Tailscale...${NC}"
    read -p "Do you want to use an auth key? (y/n): " use_auth_key
    
    if [[ "$use_auth_key" =~ ^[Yy]$ ]]; then
        read -p "Enter your Tailscale auth key: " auth_key
        tailscale up --authkey "$auth_key"
    else
        echo -e "${YELLOW}You'll need to authenticate via the web browser.${NC}"
        tailscale up
    fi
    
    echo -e "${GREEN}Tailscale authentication completed${NC}"
    echo -e "${YELLOW}Your Tailscale IP is: $(tailscale ip -4)${NC}"
}

# Function to setup VPS (public facing server)
setup_vps() {
    echo -e "${YELLOW}Setting up VPS for port forwarding...${NC}"
    
    # Enable IP forwarding
    sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    
    # Install iptables if not present
    if ! command -v iptables &> /dev/null; then
        if command -v apt-get &> /dev/null; then
            apt-get install -y iptables
        elif command -v yum &> /dev/null; then
            yum install -y iptables
        fi
    fi
    
    # Get Tailscale IP of home server
    read -p "Enter the Tailscale IP of your home server: " home_ip
    
    # Setup port forwarding
    read -p "Enter the ports you want to forward (comma separated, e.g. 80,443): " ports
    
    IFS=',' read -ra PORT_ARRAY <<< "$ports"
    for port in "${PORT_ARRAY[@]}"; do
        # Clear any existing rules
        iptables -t nat -D PREROUTING -p tcp --dport "$port" -j DNAT --to-destination "$home_ip:$port" 2>/dev/null
        iptables -D FORWARD -p tcp -d "$home_ip" --dport "$port" -j ACCEPT 2>/dev/null
        
        # Add new rules
        iptables -t nat -A PREROUTING -p tcp --dport "$port" -j DNAT --to-destination "$home_ip:$port"
        iptables -A FORWARD -p tcp -d "$home_ip" --dport "$port" -j ACCEPT
        
        echo -e "${GREEN}Port $port forwarded to $home_ip:$port${NC}"
    done
    
    # Save iptables rules
    if command -v iptables-save &> /dev/null; then
        iptables-save > /etc/iptables.rules
        echo -e "${YELLOW}To make iptables rules persistent:${NC}"
        echo -e "For Debian/Ubuntu: install iptables-persistent"
        echo -e "For CentOS/RHEL: install iptables-service and enable it"
    fi
    
    echo -e "${GREEN}VPS setup completed${NC}"
}

# Function to setup home server (private server)
setup_home_server() {
    echo -e "${YELLOW}Setting up home server...${NC}"
    
    # No need for VPS IP - connections are outbound to Tailscale network
    
    # Just ensure services are running on the specified ports
    read -p "Enter the ports you want to make available through VPS (comma separated, e.g. 80,443): " ports
    
    IFS=',' read -ra PORT_ARRAY <<< "$ports"
    for port in "${PORT_ARRAY[@]}"; do
        echo -e "${YELLOW}Ensure your service is running on port $port${NC}"
        echo -e "The VPS will forward traffic to this port through Tailscale"
    done
    
    echo -e "${GREEN}Home server setup completed${NC}"
    echo -e "${YELLOW}Make sure your Tailscale IP is ${GREEN}$(tailscale ip -4)${YELLOW} and you've provided it to the VPS setup${NC}"
}

# Main menu
while true; do
    echo -e "${YELLOW}\nVPS and Home Server Connection Script${NC}"
    echo "1. Install Tailscale"
    echo "2. Authenticate Tailscale"
    echo "3. Setup VPS (public server with port forwarding)"
    echo "4. Setup Home Server (private server)"
    echo "5. Exit"

    read -p "Select an option (1-5): " option

    case $option in
        1)
            install_tailscale
            ;;
        2)
            auth_tailscale
            ;;
        3)
            setup_vps
            ;;
        4)
            setup_home_server
            ;;
        5)
            echo -e "${GREEN}Exiting...${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option${NC}"
            ;;
    esac
done
