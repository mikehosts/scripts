#!/usr/bin/env bash
set -euo pipefail

need_root() {
  [[ "$(id -u)" -eq 0 ]] || { echo "Run as root: sudo $0"; exit 1; }
}

prompt_default() {
  local varname="$1" prompt="$2" def="$3"
  local val
  read -r -p "$prompt [$def]: " val
  val="${val:-$def}"
  printf -v "$varname" '%s' "$val"
}

prompt_required() {
  local varname="$1" prompt="$2"
  local val=""
  while [[ -z "$val" ]]; do
    read -r -p "$prompt: " val
  done
  printf -v "$varname" '%s' "$val"
}

prompt_secret() {
  local varname="$1" prompt="$2"
  local val=""
  while [[ -z "$val" ]]; do
    read -r -s -p "$prompt: " val
    echo
  done
  printf -v "$varname" '%s' "$val"
}

need_root

echo "=== IMAP → Shutdown Setup ==="
echo
echo "DEFAULTS (press Enter to accept):"
echo "------------------------------------------------"
echo "IMAP port           : 993"
echo "Use SSL             : yes"
echo "Use STARTTLS        : no"
echo "Mailbox             : INBOX"
echo "Poll interval       : 30 seconds"
echo "Trigger phrase      : Critically Low"
echo "Shutdown delay      : 0 minutes (immediate)"
echo "Log file            : /var/log/battery_alert.log"
echo "Service name        : imap-battery-watch"
echo "Run user            : batterywatch"
echo "------------------------------------------------"
echo

prompt_required IMAP_HOST "IMAP host (e.g. imap.example.com)"
prompt_default IMAP_PORT "IMAP port" "993"

prompt_default IMAP_USE_SSL "Use SSL? (y/n)" "y"
IMAP_USE_SSL="$(echo "$IMAP_USE_SSL" | tr '[:upper:]' '[:lower:]')"

prompt_default IMAP_USE_STARTTLS "Use STARTTLS? (y/n)" "n"
IMAP_USE_STARTTLS="$(echo "$IMAP_USE_STARTTLS" | tr '[:upper:]' '[:lower:]')"

prompt_required IMAP_USER "IMAP username"
prompt_secret IMAP_PASS "IMAP password"

prompt_default MAILBOX "Mailbox to watch" "INBOX"
prompt_default POLL_SECONDS "Poll interval (seconds)" "30"
prompt_default PHRASE "Trigger phrase" "Critically Low"
prompt_default SHUTDOWN_DELAY "Shutdown delay in minutes (0 = now)" "0"
prompt_default LOG_PATH "Log file path" "/var/log/battery_alert.log"
prompt_default SERVICE_NAME "systemd service name" "imap-battery-watch"
prompt_default RUN_USER "Local user to run service as" "batterywatch"

SCRIPT_PATH="/usr/local/bin/imap_battery_watch.py"
ENV_PATH="/etc/${SERVICE_NAME}.env"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
SUDOERS_PATH="/etc/sudoers.d/${SERVICE_NAME}"

echo
echo "=== Final Configuration ==="
echo "IMAP server     : $IMAP_HOST:$IMAP_PORT"
echo "Use SSL         : $IMAP_USE_SSL"
echo "Use STARTTLS    : $IMAP_USE_STARTTLS"
echo "Mailbox         : $MAILBOX"
echo "Trigger phrase  : $PHRASE"
echo "Poll interval   : $POLL_SECONDS"
echo "Shutdown delay  : $SHUTDOWN_DELAY"
echo "Run user        : $RUN_USER"
echo "Service name    : $SERVICE_NAME"
echo

read -r -p "Continue? (y/n) [y]: " CONFIRM
CONFIRM="${CONFIRM:-y}"
CONFIRM="$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')"
[[ "$CONFIRM" == "y" || "$CONFIRM" == "yes" ]] || exit 1

echo "Installing dependencies..."
apt-get update -y
apt-get install -y python3

if ! id "$RUN_USER" >/dev/null 2>&1; then
  echo "Creating user $RUN_USER"
  useradd --system --create-home --shell /usr/sbin/nologin "$RUN_USER"
fi

touch "$LOG_PATH"
chown "$RUN_USER":"$RUN_USER" "$LOG_PATH"
chmod 0640 "$LOG_PATH"

echo "Writing watcher script..."
cat > "$SCRIPT_PATH" <<'PY'
#!/usr/bin/env python3
import imaplib, email, os, time, subprocess

def env(name, default=None):
    v = os.getenv(name)
    if not v:
        if default is None:
            raise SystemExit(f"Missing env var: {name}")
        return default
    return v

IMAP_HOST = env("IMAP_HOST")
IMAP_PORT = int(env("IMAP_PORT"))
IMAP_USER = env("IMAP_USER")
IMAP_PASS = env("IMAP_PASS")
MAILBOX   = env("MAILBOX", "INBOX")

USE_SSL      = env("IMAP_USE_SSL", "y").lower() in ("y","yes","1","true")
USE_STARTTLS= env("IMAP_USE_STARTTLS", "n").lower() in ("y","yes","1","true")

PHRASE = env("PHRASE", "Critically Low")
POLL_SECONDS = int(env("POLL_SECONDS", "30"))
SHUTDOWN_DELAY_MIN = int(env("SHUTDOWN_DELAY_MIN", "0"))
LOG_PATH = env("LOG_PATH", "/var/log/battery_alert.log")

def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    try:
        with open(LOG_PATH, "a") as f:
            f.write(f"[{ts}] {msg}\n")
    except Exception:
        pass

def connect():
    if USE_SSL:
        M = imaplib.IMAP4_SSL(IMAP_HOST, IMAP_PORT)
    else:
        M = imaplib.IMAP4(IMAP_HOST, IMAP_PORT)
        if USE_STARTTLS:
            M.starttls()
    M.login(IMAP_USER, IMAP_PASS)
    return M

def extract_text(msg):
    parts = [msg.get("Subject","")]
    if msg.is_multipart():
        for p in msg.walk():
            if p.get_content_type() in ("text/plain","text/html"):
                payload = p.get_payload(decode=True)
                if payload:
                    parts.append(payload.decode(errors="ignore"))
    else:
        payload = msg.get_payload(decode=True)
        if payload:
            parts.append(payload.decode(errors="ignore"))
    return "\n".join(parts)

def shutdown_now():
    if SHUTDOWN_DELAY_MIN > 0:
        log(f"Trigger matched. Shutdown in {SHUTDOWN_DELAY_MIN} min.")
        subprocess.run(["sudo","/sbin/shutdown","-h",f"+{SHUTDOWN_DELAY_MIN}",
                        "Battery Critically Low email trigger"], check=False)
    else:
        log("Trigger matched. Shutting down now.")
        subprocess.run(["sudo","/sbin/shutdown","-h","now",
                        "Battery Critically Low email trigger"], check=False)

def main():
    log("Watcher started.")
    while True:
        try:
            M = connect()
            M.select(MAILBOX)
            typ, data = M.search(None, "(UNSEEN)")
            if typ == "OK":
                for num in data[0].split():
                    typ, msgdata = M.fetch(num, "(RFC822)")
                    if typ != "OK": continue
                    msg = email.message_from_bytes(msgdata[0][1])
                    text = extract_text(msg)
                    if PHRASE in text:
                        M.store(num, "+FLAGS", "\\Seen")
                        M.logout()
                        shutdown_now()
                        return
                    M.store(num, "+FLAGS", "\\Seen")
            M.logout()
        except Exception as e:
            log(f"Error: {e}")
        time.sleep(POLL_SECONDS)

if __name__ == "__main__":
    main()
PY

chmod 0755 "$SCRIPT_PATH"

echo "Writing env file..."
cat > "$ENV_PATH" <<EOF
IMAP_HOST=$IMAP_HOST
IMAP_PORT=$IMAP_PORT
IMAP_USER=$IMAP_USER
IMAP_PASS=$IMAP_PASS
MAILBOX=$MAILBOX
IMAP_USE_SSL=$IMAP_USE_SSL
IMAP_USE_STARTTLS=$IMAP_USE_STARTTLS
PHRASE=$PHRASE
POLL_SECONDS=$POLL_SECONDS
SHUTDOWN_DELAY_MIN=$SHUTDOWN_DELAY
LOG_PATH=$LOG_PATH
EOF

chmod 0640 "$ENV_PATH"
chown root:"$RUN_USER" "$ENV_PATH"

echo "Writing sudoers rule..."
cat > "$SUDOERS_PATH" <<EOF
$RUN_USER ALL=(root) NOPASSWD: /sbin/shutdown
EOF

chmod 0440 "$SUDOERS_PATH"
visudo -c -f "$SUDOERS_PATH" >/dev/null

echo "Writing systemd service..."
cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=IMAP Battery Alert Shutdown Watcher
After=network-online.target
Wants=network-online.target

[Service]
User=$RUN_USER
EnvironmentFile=$ENV_PATH
ExecStart=$SCRIPT_PATH
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME.service"

echo
echo "=== Done ==="
systemctl --no-pager status "$SERVICE_NAME.service" || true
echo
echo "Test by sending an email containing:"
echo "  $PHRASE"
echo "to: $IMAP_USER"
