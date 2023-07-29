#!/bin/bash

# Array of available Minecraft versions
versions=("1.8" "1.8.8" "1.9" "1.10" "1.11" "1.12" "1.13" "1.14" "1.15" "1.16" "1.17" "1.18" "1.19" "1.20.1")

# Function to install and start the Minecraft server for the specified version
install_and_start_server() {
    local version=$1
    local server_jar="minecraft_server.$version.jar"

    # Download the Minecraft server jar file for the specified version
    echo "Downloading Minecraft Server $version..."
    curl -o $server_jar "https://s3.amazonaws.com/Minecraft.Download/versions/$version/minecraft_server.$version.jar"

    # Start the server
    echo "Starting Minecraft Server $version..."
    java -Xmx2G -Xms1G -jar $server_jar nogui
}

# Prompt user to select a version
echo "Please select a Minecraft version:"
for ((i = 0; i < ${#versions[@]}; i++)); do
    echo "$((i+1)). Minecraft ${versions[i]}"
done

# Read user input
read -p "Enter the number for the desired version: " choice

# Check if the choice is within the valid range
if ((choice >= 1 && choice <= ${#versions[@]})); then
    # Subtract 1 from the choice to get the array index
    index=$((choice - 1))
    selected_version=${versions[index]}
    install_and_start_server $selected_version
else
    echo "Invalid choice. Please select a valid number."
fi
