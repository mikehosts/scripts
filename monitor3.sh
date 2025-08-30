#!/bin/bash

# --- Color Definitions ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Check for Root Privileges ---
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: This script must be run with sudo or as root.${NC}"
  echo "Please run it as: sudo ./setup.sh"
  exit 1
fi

# --- Function to Install Dependencies ---
install_dependencies() {
    ROLE=$1
    echo -e "${YELLOW}Updating package lists...${NC}"
    apt-get update -y > /dev/null 2>&1

    echo -e "${YELLOW}Installing Python3, PIP, and required tools...${NC}"
    apt-get install -y python3 python3-pip > /dev/null 2>&1

    echo -e "${YELLOW}Installing required Python libraries...${NC}"
    # Force a modern version of discord.py
    pip3 install --upgrade "discord.py>=2.0.0" flask requests psutil py-cpuinfo > /dev/null 2>&1
    echo -e "${GREEN}Dependencies installed successfully.${NC}"
}

# --- Determine User and Working Directory ---
if [ -n "$SUDO_USER" ]; then
    RUN_USER=$SUDO_USER
else
    RUN_USER=$(whoami)
fi
WORK_DIR=$(pwd)

# --- Main Setup Logic ---
echo -e "${GREEN}--- Ubuntu Server Monitoring Bot Setup ---${NC}"
read -p "Is this a 'master' or a 'slave' server? " ROLE
ROLE=$(echo "$ROLE" | tr '[:upper:]' '[:lower:]')

if [ "$ROLE" == "master" ]; then
    # --- MASTER SETUP ---
    echo -e "\n${YELLOW}--- Configuring Master Server ---${NC}"
    install_dependencies "master"

    read -p "Enter the IP address for the master to listen on [0.0.0.0]: " HOST_IP; HOST_IP=${HOST_IP:-0.0.0.0}
    read -p "Enter the port for the master to listen on [5000]: " HOST_PORT; HOST_PORT=${HOST_PORT:-5000}
    
    echo -e "\n${CYAN}--- Discord Bot Setup Instructions ---${NC}"
    echo -e "1. Go to: ${CYAN}https://discord.com/developers/applications${NC}"
    echo -e "2. Click ${CYAN}'New Application'${NC}, give it a name, and agree to the ToS."
    echo -e "3. Go to the ${CYAN}'Bot'${NC} tab."
    echo -e "4. ${RED}IMPORTANT:${NC} Under 'Privileged Gateway Intents', enable the ${CYAN}'SERVER MEMBERS INTENT'${NC}."
    echo -e "5. Click ${CYAN}'Reset Token'${NC} to get your Bot Token. Copy it now."
    echo -e "6. Go to the ${CYAN}'OAuth2 -> URL Generator'${NC} tab. Select the ${CYAN}'bot'${NC} scope."
    echo -e "7. In 'Bot Permissions', select ${CYAN}'View Channel'${NC}, ${CYAN}'Send Messages'${NC}, and ${CYAN}'Read Message History'${NC}."
    echo -e "8. Copy the generated URL at the bottom, paste it in your browser, and invite the bot to your server."
    echo -e "9. In Discord, enable Developer Mode (${CYAN}User Settings -> Advanced${NC}), then right-click your target channel and ${CYAN}'Copy Channel ID'${NC}."
    echo -e "-------------------------------------------"
    read -p "Enter your Discord Bot Token: " BOT_TOKEN
    read -p "Enter the Discord Channel ID for updates: " CHANNEL_ID

    # Create the Python script for the master
    cat << EOF > ${WORK_DIR}/master.py
import discord, asyncio, threading, json, time, os
from flask import Flask, request, jsonify

# --- CONFIGURATION ---
BOT_TOKEN = "${BOT_TOKEN}"
CHANNEL_ID = ${CHANNEL_ID}
HOST_IP = "${HOST_IP}"
HOST_PORT = ${HOST_PORT}
STATE_FILE = "message_ids.json"
# ---------------------

# --- State Management ---
slave_message_map = {}
def load_state():
    global slave_message_map
    if os.path.exists(STATE_FILE):
        with open(STATE_FILE, 'r') as f: slave_message_map = json.load(f)
    print(f"Loaded state: {len(slave_message_map)} slaves tracked.")
def save_state():
    with open(STATE_FILE, 'w') as f: json.dump(slave_message_map, f, indent=4)

# --- Discord Bot & Flask Communication ---
intents = discord.Intents.default()
intents.members = True # Required for some server information
client = discord.Client(intents=intents)
update_queue = asyncio.Queue()
app = Flask(__name__)

@app.route('/update', methods=['POST'])
def update():
    data = request.json
    print(f"Received data from: {data.get('name', 'Unknown Slave')}")
    if not data or 'name' not in data: return jsonify({"status": "error"}), 400
    client.loop.call_soon_threadsafe(update_queue.put_nowait, data)
    return jsonify({"status": "success"}), 200

def run_flask():
    print("Starting Flask server...")
    app.run(host=HOST_IP, port=HOST_PORT)

# --- Discord Bot Logic ---
async def update_processor():
    await client.wait_until_ready()
    channel = client.get_channel(CHANNEL_ID)
    if not channel:
        print(f"FATAL ERROR: Cannot find channel with ID {CHANNEL_ID}. Check the ID and bot permissions.")
        return

    print("Discord update processor is running and connected to channel.")
    while not client.is_closed():
        data = await update_queue.get()
        slave_name = data.get('name')
        print(f"Processing update for {slave_name}...")

        embed = discord.Embed(title=f"📊 Status Update for {slave_name}", color=discord.Color.blue())
        embed.add_field(name="IP", value=data.get('ip', 'N/A'), inline=True)
        embed.add_field(name="CPU Usage", value=f"**{data.get('cpu_usage', 0)}%**", inline=True)
        embed.add_field(name="RAM Usage", value=f"{data.get('ram_usage', 0)}%", inline=True)
        embed.add_field(name="CPU", value=f"{data.get('cpu_make', 'N/A')}", inline=False)
        embed.add_field(name="CPU Details", value=f"{data.get('cpu_ghz', 'N/A')} GHz | {data.get('cpu_threads', 'N/A')} Threads", inline=True)
        embed.add_field(name="Disk Usage", value=f"{data.get('disk_usage', 0)}%", inline=True)
        embed.set_footer(text=f"Last updated: {time.ctime()}")
        
        message_id = slave_message_map.get(slave_name)
        try:
            if message_id: message = await channel.fetch_message(message_id); await message.edit(embed=embed)
            else: raise discord.NotFound(None, "No local message ID")
        except discord.NotFound:
            print(f"Message for {slave_name} not found, sending a new one.")
            new_message = await channel.send(embed=embed)
            slave_message_map[slave_name] = new_message.id
            save_state()
        except Exception as e:
            print(f"ERROR updating message for {slave_name}: {e}")

@client.event
async def on_ready():
    print(f'Discord bot logged in as {client.user}')
    load_state()
    client.loop.create_task(update_processor())

# --- Main Execution ---
if __name__ == "__main__":
    threading.Thread(target=run_flask, daemon=True).start()
    try: client.run(BOT_TOKEN)
    except discord.errors.LoginFailure: print("FATAL ERROR: Login failed. The bot token is invalid.")
    except Exception as e: print(f"FATAL ERROR running bot: {e}")
EOF
    echo -e "${GREEN}Master Python script created.${NC}"
    
    # --- Create Diagnostic Script ---
    cat << EOF > ${WORK_DIR}/check_bot.py
import discord, sys
async def main():
    if len(sys.argv) != 3:
        print("Usage: python3 check_bot.py <BOT_TOKEN> <CHANNEL_ID>")
        return
    TOKEN, CHANNEL_ID = sys.argv[1], int(sys.argv[2])
    intents = discord.Intents.default()
    client = discord.Client(intents=intents)
    try:
        @client.event
        async def on_ready():
            print(f"✅ Logged in successfully as {client.user}")
            channel = client.get_channel(CHANNEL_ID)
            if channel:
                print(f"✅ Found channel: '{channel.name}'")
                await channel.send("✅ Diagnostic check successful. I am online and have permission to send messages here.")
                print("✅ Test message sent successfully.")
            else:
                print(f"❌ ERROR: Channel with ID {CHANNEL_ID} not found. Check the ID and ensure the bot is in the server.")
            await client.close()
        await client.start(TOKEN)
    except discord.errors.LoginFailure:
        print("❌ FATAL ERROR: Login failed. The provided Bot Token is invalid.")
    except Exception as e:
        print(f"❌ An unexpected error occurred: {e}")
if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
EOF
    echo -e "${GREEN}Diagnostic script created.${NC}"

    # --- Run Diagnostic ---
    read -p "Do you want to run a diagnostic test to check the bot token and channel ID? (y/n) " RUN_DIAG
    if [ "$RUN_DIAG" == "y" ]; then
        echo -e "${YELLOW}--- Running Diagnostic Test ---${NC}"
        python3 ${WORK_DIR}/check_bot.py "${BOT_TOKEN}" "${CHANNEL_ID}"
        echo -e "${YELLOW}----------------------------${NC}"
    fi

    SERVICE_NAME="master_monitor.service"
    cat << EOF > /etc/systemd/system/${SERVICE_NAME}
[Unit]
Description=Master Monitoring Bot
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
    # --- SLAVE SETUP (remains the same) ---
    echo -e "\n${YELLOW}--- Configuring Slave Server ---${NC}"
    install_dependencies "slave"

    read -p "Enter a name for this slave server [My Web Server]: " SLAVE_NAME; SLAVE_NAME=${SLAVE_NAME:-My Web Server}
    DEFAULT_IP=$(hostname -I | awk '{print $1}'); read -p "Enter IP of this slave [${DEFAULT_IP}]: " SLAVE_IP; SLAVE_IP=${SLAVE_IP:-$DEFAULT_IP}
    read -p "Enter the master server's IP address: " MASTER_IP
    read -p "Enter the master server's port [5000]: " MASTER_PORT; MASTER_PORT=${MASTER_PORT:-5000}
    MASTER_URL="http://${MASTER_IP}:${MASTER_PORT}/update"
    read -p "Update interval in seconds? [60]: " UPDATE_INTERVAL; UPDATE_INTERVAL=${UPDATE_INTERVAL:-60}

    cat << EOF > ${WORK_DIR}/slave.py
import psutil, requests, time, os
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
    except Exception: cpu_make, cpu_ghz, cpu_threads = "N/A", "N/A", "N/A"
    return {"name": SLAVE_NAME, "ip": SLAVE_IP, "cpu_make": cpu_make, "cpu_ghz": cpu_ghz,
        "cpu_threads": cpu_threads, "cpu_usage": psutil.cpu_percent(interval=1),
        "ram_usage": psutil.virtual_memory().percent, "swap_usage": psutil.swap_memory().percent,
        "disk_usage": psutil.disk_usage('/').percent,}

if __name__ == '__main__':
    while True:
        try:
            requests.post(MASTER_API_URL, json=get_system_info(), timeout=10)
        except requests.exceptions.RequestException as e:
            print(f"[{time.ctime()}] Error sending data: {e}")
        time.sleep(UPDATE_INTERVAL)
EOF
    echo -e "${GREEN}Slave Python script created.${NC}"

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
    echo -e "${RED}Invalid role entered. Please run the script again.${NC}"
    exit 1
fi

# --- Enable and Start the Service ---
echo -e "\n${YELLOW}Creating and enabling systemd service...${NC}"
systemctl daemon-reload
systemctl enable ${SERVICE_NAME}
systemctl restart ${SERVICE_NAME}

echo -e "\n${GREEN}--- ✅ Setup Complete! ---${NC}"
echo "The ${ROLE} service has been started and enabled to run on boot."
echo "Check its status with: ${YELLOW}sudo systemctl status ${SERVICE_NAME}${NC}"
echo "View live logs with: ${YELLOW}sudo journalctl -u ${SERVICE_NAME} -f${NC}"
