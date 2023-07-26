#!/bin/bash

# Function to install Java based on the specified version
install_java() {
  java_version="$1"
  # Add code here to install Java based on the provided version
  # For example, to install OpenJDK 11:
  if [[ "$java_version" == "11" ]]; then
    apt-get update
    apt-get install -y openjdk-11-jre-headless
  elif [[ "$java_version" == "8" ]]; then
    apt-get update
    apt-get install -y openjdk-8-jre-headless
  elif [[ "$java_version" == "17" ]]; then
    apt-get update
    apt-get install -y openjdk-17-jre-headless
  else
    echo "Unsupported Java version: $java_version"
    exit 1
  fi
}

# Function to install Paper Minecraft server based on the specified version
install_paper_minecraft() {
  minecraft_version="$1"
  # Add code here to install Paper Minecraft based on the provided version
  # For example, to download Paper for the given version:
  wget -O paper.jar "https://papermc.io/api/v2/projects/paper/versions/$minecraft_version/builds/latest/downloads/paper-$minecraft_version-latest.jar"
}

# Function to show "DuckHost.pro" in rainbow colors
show_rainbow_text() {
  echo -e "\033[31mD\033[33mu\033[32mc\033[36mk\033[34mH\033[35mo\033[31ms\033[33mt\033[32m.\033[36mp\033[34mr\033[35mo"
  sleep 1
  echo -e "\033[31mD\033[33mu\033[32mc\033[36mk\033[34mH\033[35mo\033[31ms\033[33mt\033[32m.\033[36mp\033[34mr\033[35mo"
  sleep 1
  echo -e "\033[31mD\033[33mu\033[32mc\033[36mk\033[34mH\033[35mo\033[31ms\033[33mt\033[32m.\033[36mp\033[34mr\033[35mo"
}

# Function to check for incoming network connections on the specified port
check_for_connection() {
  port="$1"
  while true; do
    nc -z localhost "$port"
    if [ $? -eq 0 ]; then
      return 0
    fi
    sleep 1
  done
}

# Function to start the Minecraft server with the specified memory
start_minecraft_server() {
  memory="$1"
  # Add code here to start the Minecraft server using the previously installed version
  # Example: You can use java to start the server
  # For example, to start the server with 2GB memory allocation:
  # java -Xmx2G -Xms2G -jar paper.jar nogui
}

# Function to stop the Minecraft server
stop_minecraft_server() {
  # Add code here to gracefully stop the Minecraft server using the "stop" command
  screen -S minecraft -X stuff "stop^M" # (Note: ^M should be a literal Enter/Return character)
}

# Main script starts here
if [ $# -ne 4 ]; then
  echo "Usage: $0 java-ver mc-ver port memory"
  exit 1
fi

java_version="$1"
minecraft_versions="$2" # Multiple versions separated by spaces, e.g., "1.16.5 1.17.1"
port="$3"
memory="$4"

# Install Java based on the provided version
install_java "$java_version"

# Try installing each Minecraft version until one works
for version in $minecraft_versions; do
  install_paper_minecraft "$version"
  show_rainbow_text &
  check_for_connection "$port"

  if [ $? -eq 0 ]; then
    start_minecraft_server "$memory" &
    while true; do
      sleep 2m
      check_for_connection "$port"
      if [ $? -ne 0 ]; then
        break
      fi
    done
    sleep 2m
    stop_minecraft_server
    sleep 2m
    exit 0
  else
    # Clean up and try the next version
    rm -f paper.jar
  fi
done

echo "Failed to start Minecraft server with any of the provided versions: $minecraft_versions"
exit 1
