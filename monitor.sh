#!/bin/bash

# --- Color Definitions ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Check for Root Privileges ---
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: This script must be run with sudo or as root.${NC}"
  echo "Please run it as: sudo ./setup.sh"
  exit 1
fi

# --- Function to Install Dependencies ---
install_dependencies() {
    echo -e "${YELLOW}Updating package lists...${NC}"
    apt-get update -y > /dev/null 2>&1

    echo -e "${YELLOW}Installing Python3, PIP, and required tools...${NC}"
    apt-get install -y python3 python3-pip > /dev/null 2>&1

    echo -e "${YELLOW}Installing required Python libraries...${NC}"
    pip3 install flask requests psutil py-cpuinfo > /dev/null 2>&1
    echo -e "${GREEN}Dependencies installed successfully.${NC}"
}

# --- Determine User and Working Directory ---
# If script is run with sudo, SUDO_USER will be the original user
if [ -n "$SUDO_USER" ]; then
    RUN_USER=$SUDO_USER
else
    RUN_USER=$(whoami)
fi
WORK_DIR=$(pwd)

# --- Main Setup Logic ---
echo -e "${GREEN}--- Ubuntu Server Monitoring Setup ---${NC}"
echo "This script will configure the server as either a master or a slave."
read -p "Is this a 'master' or a 'slave' server? " ROLE

ROLE=$(echo "$ROLE" | tr '[:upper:]' '[:lower:]') # Convert to lowercase

if [ "$ROLE" == "master" ]; then
    # --- MASTER SETUP ---
    echo -e "\n${YELLOW}--- Configuring Master Server ---${NC}"
    install_dependencies

    read -p "Enter the IP address for the master to listen on [0.0.0.0]: " HOST_IP
    HOST_IP=${HOST_IP:-0.0.0.0}

    read -p "Enter the port for the master to listen on [5000]: " HOST_PORT
    HOST_PORT=${HOST_PORT:-5000}

    read -p "Enter your Discord Webhook URL: " DISCORD_WEBHOOK_URL

    # Create the Python script for the master
    cat << EOF > ${WORK_DIR}/master.py
from flask import Flask, request, jsonify
import requests
import json
import time

app = Flask(__name__)

# --- CONFIGURATION ---
DISCORD_WEBHOOK_URL = "${DISCORD_WEBHOOK_URL}"
# ---------------------

@app.route('/update', methods=['POST'])
def update():
    data = request.json
    if not data:
        return jsonify({"status": "error", "message": "No data received"}), 400

    try:
        embed = {
            "title": f"📊 Status Update for {data.get('name', 'N/A')}",
            "color": 3447003,
            "fields": [
                {"name": "IP Address", "value": data.get('ip', 'N/A'), "inline": True},
                {"name": "CPU", "value": f"{data.get('cpu_make', 'N/A')}", "inline": False},
                {"name": "CPU Details", "value": f"{data.get('cpu_ghz', 'N/A')} GHz | {data.get('cpu_threads', 'N/A')} Threads", "inline": True},
                {"name": "CPU Usage", "value": f"**{data.get('cpu_usage', 0)}%**", "inline": True},
                {"name": "RAM Usage", "value": f"{data.get('ram_usage', 0)}%", "inline": True},
                {"name": "Swap Usage", "value": f"{data.get('swap_usage', 0)}%", "inline": True},
                {"name": "Disk Usage", "value": f"{data.get('disk_usage', 0)}%", "inline": True},
            ],
            "footer": {"text": f"Last updated: {time.ctime()}"}
        }
        payload = {"embeds": [embed]}
        requests.post(DISCORD_WEBHOOK_URL, json=payload, timeout=10)
        return jsonify({"status": "success"}), 200
    except Exception as e:
        print(f"Error processing request: {e}")
        return jsonify({"status": "error", "message": "Internal server error"}), 500

if __name__ == '__main__':
    app.run(host='${HOST_IP}', port=${HOST_PORT})
EOF
    echo -e "${GREEN}Master Python script created at ${WORK_DIR}/master.py${NC}"
    
    # Create systemd service file
    SERVICE_NAME="master_monitor.service"
    cat << EOF > /etc/systemd/system/${SERVICE_NAME}
[Unit]
Description=Master Monitoring API
After=network.target

[Service]
User=${RUN_USER}
WorkingDirectory=${WORK_DIR}
ExecStart=/usr/bin/python3 ${WORK_DIR}/master.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

elif [ "$ROLE" == "slave" ]; then
    # --- SLAVE SETUP ---
    echo -e "\n${YELLOW}--- Configuring Slave Server ---${NC}"
    install_dependencies

    read -p "Enter a name for this slave server [My Web Server]: " SLAVE_NAME
    SLAVE_NAME=${SLAVE_NAME:-My Web Server}

    DEFAULT_IP=$(hostname -I | awk '{print $1}')
    read -p "Enter the IP address of this slave server [${DEFAULT_IP}]: " SLAVE_IP
    SLAVE_IP=${SLAVE_IP:-$DEFAULT_IP}
    
    read -p "Enter the master server's IP address: " MASTER_IP
    read -p "Enter the master server's port [5000]: " MASTER_PORT
    MASTER_PORT=${MASTER_PORT:-5000}
    MASTER_URL="http://${MASTER_IP}:${MASTER_PORT}/update"

    read -p "How often (in seconds) should this slave send updates? [60]: " UPDATE_INTERVAL
    UPDATE_INTERVAL=${UPDATE_INTERVAL:-60}

    # Create the Python script for the slave
    cat << EOF > ${WORK_DIR}/slave.py
import psutil
import requests
import time
import os
from cpuinfo import get_cpu_info

# --- CONFIGURATION ---
SLAVE_NAME = "${SLAVE_NAME}"
SLAVE_IP = "${SLAVE_IP}"
MASTER_API_URL = "${MASTER_URL}"
UPDATE_INTERVAL = ${UPDATE_INTERVAL}
# ---------------------

def get_system_info():
    try:
        cpu_info = get_cpu_info()
        cpu_make = cpu_info.get('brand_raw', 'N/A')
        cpu_ghz_friendly = cpu_info.get('hz_actual_friendly', cpu_info.get('hz_advertised_friendly', '0.0 GHz'))
        cpu_ghz = round(float(cpu_ghz_friendly.split()[0]), 2)
        cpu_threads = os.cpu_count()
    except Exception:
        cpu_make, cpu_ghz, cpu_threads = "N/A", "N/A", "N/A"

    return {
        "name": SLAVE_NAME,
        "ip": SLAVE_IP,
        "cpu_make": cpu_make,
        "cpu_ghz": cpu_ghz,
        "cpu_threads": cpu_threads,
        "cpu_usage": psutil.cpu_percent(interval=1),
        "ram_usage": psutil.virtual_memory().percent,
        "swap_usage": psutil.swap_memory().percent,
        "disk_usage": psutil.disk_usage('/').percent,
    }

def send_data(data):
    try:
        response = requests.post(MASTER_API_URL, json=data, timeout=10)
        if response.status_code == 200:
            print(f"[{time.ctime()}] Data sent successfully")
        else:
            print(f"[{time.ctime()}] Failed to send data: {response.status_code} - {response.text}")
    except requests.exceptions.RequestException as e:
        print(f"[{time.ctime()}] Error sending data: {e}")

if __name__ == '__main__':
    while True:
        system_info = get_system_info()
        send_data(system_info)
        time.sleep(UPDATE_INTERVAL)
EOF
    echo -e "${GREEN}Slave Python script created at ${WORK_DIR}/slave.py${NC}"

    # Create systemd service file
    SERVICE_NAME="slave_monitor.service"
    cat << EOF > /etc/systemd/system/${SERVICE_NAME}
[Unit]
Description=Slave Monitoring Agent
After=network.target

[Service]
User=${RUN_USER}
WorkingDirectory=${WORK_DIR}
ExecStart=/usr/bin/python3 ${WORK_DIR}/slave.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

else
    echo -e "${RED}Invalid role entered. Please run the script again and choose 'master' or 'slave'.${NC}"
    exit 1
fi

# --- Enable and Start the Service ---
echo -e "\n${YELLOW}Creating and enabling systemd service...${NC}"
systemctl daemon-reload
systemctl enable ${SERVICE_NAME}
systemctl start ${SERVICE_NAME}

echo -e "\n${GREEN}--- ✅ Setup Complete! ---${NC}"
echo "The ${ROLE} service has been started and enabled to run on boot."
echo "You can check its status with the command:"
echo -e "${YELLOW}sudo systemctl status ${SERVICE_NAME}${NC}"
echo "You can view its logs with the command:"
echo -e "${YELLOW}sudo journalctl -u ${SERVICE_NAME} -f${NC}"
