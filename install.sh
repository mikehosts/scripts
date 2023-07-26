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
if [ ! -f "minecraft_vars.txt" ]; then
  echo "Error: minecraft_vars.txt not found!"
  exit 1
fi

# Read the variables from the minecraft_vars.txt file
source minecraft_vars.txt

if [ -z "$JAVA_VER" ] || [ -z "$MC_VER" ] || [ -z "$SERVER_PORT" ] || [ -z "$SERVER_MEMORY" ]; then
  echo "Error: One or more variables not set in minecraft_vars.txt"
  exit 1
fi

install_java "$JAVA_VER"
install_paper_minecraft "$MC_VER"
show_rainbow_text &
check_for_connection "$SERVER_PORT"

if [ $? -eq 0 ]; then
  start_minecraft_server "$SERVER_MEMORY" &
  while true; do
    sleep 2m
    check_for_connection "$SERVER_PORT"
    if [ $? -ne 0 ]; then
      break
    fi
  done
  sleep 2m
  stop_minecraft_server
  sleep 2m
else
  echo "Failed to start Minecraft server with the provided variables."
  exit 1
fi
