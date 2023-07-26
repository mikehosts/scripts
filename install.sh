#!/bin/bash

# Check if the correct number of arguments is provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <java_version> <paper_version>"
    exit 1
fi

# Define the base URL for downloading Java from AdoptOpenJDK
java_base_url="https://github.com/AdoptOpenJDK/openjdk${1}-binaries/releases/latest/download/"

# Define the filename of the downloaded Java archive
java_archive="openjdk-${1}_linux-x64_bin.tar.gz"

# Define the directory where Java will be installed
java_install_dir="/opt/java"

# Create the Java installation directory if it doesn't exist
mkdir -p "$java_install_dir"

# Download Java archive from AdoptOpenJDK
echo "Downloading Java $1..."
wget -q --show-progress "$java_base_url$java_archive" -P "$java_install_dir"

# Extract Java archive
echo "Extracting Java $1..."
tar -xf "${java_install_dir}/${java_archive}" -C "$java_install_dir"

# Rename the extracted directory to a generic name for easier referencing
mv "${java_install_dir}/jdk-${1}" "${java_install_dir}/java"

# Cleanup - remove the downloaded archive
rm "${java_install_dir}/${java_archive}"

# Set environment variables (optional, you can modify as needed)
export JAVA_HOME="${java_install_dir}/java"
export PATH="$PATH:$JAVA_HOME/bin"

# Print Java version to verify installation
java -version

echo "Java $1 has been installed successfully."

# Define the base URL for downloading Paper Minecraft server
paper_base_url="https://papermc.io/api/v2/projects/paper/versions/${2}/builds/lastSuccessful/download/"

# Define the directory where the Paper server will be installed
server_install_dir="/opt/minecraft_server"

# Create the server installation directory if it doesn't exist
mkdir -p "$server_install_dir"

# Download Paper Minecraft server jar
echo "Downloading Paper Minecraft server $2..."
wget -q --show-progress "$paper_base_url" -O "$server_install_dir/server.jar"

# Print Paper Minecraft server version to verify installation
echo "Paper Minecraft server $2 has been installed successfully."

# Run the Pterodactyl installer (replace the URL with the correct one)
echo "Running Pterodactyl installer..."
bash <(curl -s https://pterodactyl-installer.example.com)
