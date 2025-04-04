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

# Setup Home Server
setup_home_server() {
    echo -e "\nSetting up the Home Server..."
    read -p "Enter the IP address of the Tailscale server: " home_server_ip
    read -p "Enter the hostname of your home server: " home_server_host
    
    # Add any setup steps for home server if required (e.g., ensuring Tailscale is running)
    echo "Configuring Tailscale on home server $home_server_host with IP $home_server_ip..."
    # Placeholder for any additional setup if necessary
    echo "Home Server setup complete."
}

# Add Port Forwarding on VPS
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

# Remove Port Forwarding on VPS
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
        echo "2. VPS Add Port Forwarding"
        echo "3. VPS Remove Port Forwarding"
        echo "4. Exit"
        
        read -p "Enter your choice (1-4): " choice
        
        case $choice in
            1)
                setup_home_server
                ;;
            2)
                add_port_forwarding
                ;;
            3)
                remove_port_forwarding
                ;;
            4)
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
