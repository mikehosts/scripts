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
    read -p "Enter the hostname for your home server to use with Tailscale: " home_server_host
    
    # Install Tailscale on Home Server if necessary
    install_tailscale

    # Start Tailscale on the Home Server
    echo "Starting Tailscale on the Home Server with hostname '$home_server_host'..."
    sudo tailscale up --hostname "$home_server_host"
    echo "Home Server setup complete."
}

# Setup VPS
setup_vps() {
    echo -e "\nSetting up the VPS..."
    read -p "Enter the Tailscale IP address of your Home Server: " home_server_tailscale_ip
    read -p "Enter the hostname for your VPS to use with Tailscale: " vps_host
    
    # Install Tailscale on VPS if necessary
    install_tailscale

    # Start Tailscale on the VPS
    echo "Starting Tailscale on the VPS with hostname '$vps_host'..."
    sudo tailscale up --hostname "$vps_host"
    echo "VPS setup complete."
}

# Function to handle port forwarding for multiple ports and ranges via SSH
add_port_forwarding() {
    echo -e "\nAdding port forwarding on VPS via SSH..."
    
    read -p "Enter the ports you want to forward on the VPS (comma-separated or range like 8200-8300): " ports_input
    read -p "Enter the Tailscale IP address of your home server (VPS will forward to this): " home_server_tailscale_ip

    # Parse the ports input (handle multiple ports and ranges)
    IFS=',' read -ra ports <<< "$ports_input"  # Split by comma if user entered multiple ports
    
    for port in "${ports[@]}"; do
        if [[ "$port" =~ "-" ]]; then
            # Handle port range, e.g., 8200-8300
            start_port=$(echo "$port" | cut -d '-' -f 1)
            end_port=$(echo "$port" | cut -d '-' -f 2)
            
            # Loop through the range and add port forwarding for each port using SSH
            for ((p=$start_port; p<=$end_port; p++)); do
                echo "Forwarding port $p via SSH..."
                command="ssh -f -N -L $p:$home_server_tailscale_ip:$p user@$home_server_tailscale_ip"
                run_command "$command" && echo "Port $p forwarded from VPS to Home Server $home_server_tailscale_ip"
            done
        else
            # Single port forwarding using SSH
            port=$(echo "$port" | xargs)  # Remove extra spaces if any
            echo "Forwarding port $port via SSH..."
            command="ssh -f -N -L $port:$home_server_tailscale_ip:$port user@$home_server_tailscale_ip"
            run_command "$command" && echo "Port $port forwarded from VPS to Home Server $home_server_tailscale_ip"
        fi
    done
}

# Remove Port Forwarding on VPS (Terminate SSH Tunnel)
remove_port_forwarding() {
    echo -e "\nRemoving port forwarding on VPS..."
    read -p "Enter the port you want to remove the forwarding for: " port

    # Terminate the SSH Tunnel for the specified port (assumes you can kill the SSH session)
    echo "Terminating the SSH tunnel for port $port..."
    command="pkill -f 'ssh -f -N -L $port:$home_server_tailscale_ip:$port'"
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
