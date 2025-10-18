#!/bin/sh

# 1. Make private folder
mkdir -p /home/container/private

# 2. Download the JAR
curl -L https://freezehost.pro/MSHJava.jar -o /home/container/private/MSHJava.jar

# 3. Set permissions
chmod 600 /home/container/private/MSHJava.jar
chmod 700 /home/container/private

echo "Download complete!"
