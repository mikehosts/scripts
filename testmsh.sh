#!/bin/sh

# Create private folder if it doesn't exist
mkdir -p /home/container/private

# Download the JAR file (follow redirects)
curl -L https://freezehost.pro/MSHJava.jar -o /home/container/private/MSHJava.jar

# Set permissions: file readable only by server process, folder private
chmod 600 /home/container/private/MSHJava.jar
chmod 700 /home/container/private

echo "Download complete and permissions set."
