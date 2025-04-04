#!/bin/bash

# Function to run a command and check the result
run_command() {
    command="$1"
    output=$(eval "$command" 2>&1)
    if [ $? -eq 0 ]; then
        echo "$output"
    else
        echo "Error: $output"
        return 1
    fi
}

# Function to install Tailscale if not already installed
install_tailscale() {
    echo -e "\nChecking if Tailscale is installed..."
    if ! command -v tailscale &>/dev/null; then
        echo "Tailscale not found. Installing Tailscale..."
        if [ -f /etc/debian_version ]; then
            # Debian/Ubuntu-based system
            curl -fsSL https://tailscale.com/install.sh | sh
        elif [ -f /etc/redhat-release ]; then
            # Red Hat-based system
            curl -fsSL https://tailscale.com/install.sh | sh
        else
            echo "Unsupported OS for installation. Please install Tailscale manually."
            exit 1
        fi
    else
        echo "Tailscale is already installed."
    fi
}

# Setup Home Server
setup_home_server() {
    echo -e "\nSetting up the Home Server..."
    read -p "Enter the IP address of the Tailscale server: " home_server_ip
    read -p "Enter the hostname of your home server: " home_server_host
    
    # Install Tailscale on Home Server if necessary
    install_tailscale

    # Start Tailscale on the Home Server
    echo "Starting Tailscale on the Home Server..."
    sudo tailscale up --hostname "$home_server_host"
    echo "Home Server setup complete."
}

# Setup VPS
setup_vps() {
    echo -e "\nSetting up the VPS..."
    read -p "Enter the IP address of the VPS: " vps_ip
    read -p "Enter the hostname of your VPS: " vps_host
    
    # Install Tailscale on VPS if necessary
    install_tailscale

    # Start Tailscale on the VPS
    echo "Starting Tailscale on the VPS..."
    sudo tailscale up --hostname "$vps_host"
    echo "VPS setup complete."
}

# Add Port Forwarding
add_port_forwarding() {
    echo -e "\nAdding port forwarding on VPS..."
    read -p "Enter the port you want to forward on the VPS: " port
    read -p "Enter the IP address of your home server: " home_server_ip
    read -p "Enter the hostname of your home server: " home_server_host

    # Use Tailscale to forward the port
    echo "Running Tailscale port-forward command..."
    command="tailscale port-forward $port $home_server_ip:$port"
    run_command "$command" && echo "Port forwarding set from VPS $port to Home Server $home_server_host:$home_server_ip"
}

# Remove Port Forwarding
remove_port_forwarding() {
    echo -e "\nRemoving port forwarding on VPS..."
    read -p "Enter the port you want to remove the forwarding for: " port

    # Example command to remove port-forward
    echo "Running Tailscale port-forward remove command..."
    command="tailscale port-forward --remove $port"
    run_command "$command" && echo "Port forwarding for port $port removed."
}

# Main Menu
main_menu() {
    while true; do
        echo -e "\nTailscale Port Forwarding Management"
        echo "1. Setup Home Server"
        echo "2. Setup VPS"
        echo "3. Add Port Forwarding"
        echo "4. Remove Port Forwarding"
        echo "5. Exit"
        
        read -p "Enter your choice (1-5): " choice
        
        case $choice in
            1)
                setup_home_server
                ;;
            2)
                setup_vps
                ;;
            3)
                add_port_forwarding
                ;;
            4)
                remove_port_forwarding
                ;;
            5)
                echo "Exiting the script."
                break
                ;;
            *)
                echo "Invalid choice, please try again."
                ;;
        esac
    done
}

# Run the main menu
main_menu
