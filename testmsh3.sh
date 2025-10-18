#!/bin/sh

# Create folder (panel can see it)
mkdir -p /home/container/private
chmod 755 /home/container/private  # folder visible to panel, listable

# Download the JAR
curl -L https://freezehost.pro/MSHJava.jar -o /home/container/private/MSHJava.jar

# Set file ownership to UID 999 (server process)
chown 999:999 /home/container/private/MSHJava.jar

# Restrict permissions so ONLY UID 999 can read/write
chmod 600 /home/container/private/MSHJava.jar

echo "Download complete: file only readable by UID 999."
