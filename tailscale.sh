#!/bin/bash
set -e

# Must run as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo)"
    exit 1
fi

install_requirements() {
    echo "=== Installing dependencies ==="
    apt-get update
    apt-get install -y curl iptables iptables-persistent netfilter-persistent
}

install_tailscale() {
    echo "=== Installing Tailscale ==="
    curl -fsSL https://tailscale.com/install.sh | sh
    tailscale up --accept-routes
    echo "Please authenticate Tailscale in your browser..."
    sleep 5
}

enable_ip_forwarding() {
    echo "=== Enabling IP forwarding ==="
    sysctl -w net.ipv4.ip_forward=1
    sed -i '/^net.ipv4.ip_forward/d' /etc/sysctl.conf
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
}

add_forward_rule() {
    read -rp "Enter Tailscale destination IP: " DEST_IP
    read -rp "Enter ports to forward (e.g. 80,443,8000-8010): " PORTS
    read -rp "Protocol (tcp/udp/both): " PROTO

    LOCAL_TS_IP=$(tailscale ip -4)

    IFS=',' read -ra PORT_ARRAY <<< "$PORTS"
    for port in "${PORT_ARRAY[@]}"; do
        if [[ "$port" == *"-"* ]]; then
            start=$(echo "$port" | cut -d'-' -f1)
            end=$(echo "$port" | cut -d'-' -f2)
            for ((p=start; p<=end; p++)); do
                forward_port "$p" "$DEST_IP" "$PROTO" "$LOCAL_TS_IP"
            done
        else
            forward_port "$port" "$DEST_IP" "$PROTO" "$LOCAL_TS_IP"
        fi
    done

    netfilter-persistent save
    echo "=== Port forwarding rule(s) added and saved ==="
}

forward_port() {
    local PORT="$1"
    local DEST="$2"
    local PROTO="$3"
    local LOCAL="$4"

    case "$PROTO" in
        tcp)
            iptables -t nat -A PREROUTING -d "$LOCAL" -p tcp --dport "$PORT" -j DNAT --to-destination "$DEST:$PORT"
            iptables -A FORWARD -p tcp -d "$DEST" --dport "$PORT" -j ACCEPT
            ;;
        udp)
            iptables -t nat -A PREROUTING -d "$LOCAL" -p udp --dport "$PORT" -j DNAT --to-destination "$DEST:$PORT"
            iptables -A FORWARD -p udp -d "$DEST" --dport "$PORT" -j ACCEPT
            ;;
        both)
            forward_port "$PORT" "$DEST" tcp "$LOCAL"
            forward_port "$PORT" "$DEST" udp "$LOCAL"
            ;;
        *)
            echo "Invalid protocol, skipping $PORT"
            ;;
    esac
}

view_rules() {
    echo "=== Current iptables NAT rules ==="
    iptables -t nat -L PREROUTING -n -v
    echo ""
    echo "=== Current iptables FORWARD rules ==="
    iptables -L FORWARD -n -v
}

remove_rule() {
    read -rp "Enter port to remove: " PORT
    read -rp "Protocol (tcp/udp/both): " PROTO
    LOCAL_TS_IP=$(tailscale ip -4)

    case "$PROTO" in
        tcp)
            iptables -t nat -D PREROUTING -d "$LOCAL_TS_IP" -p tcp --dport "$PORT" -j DNAT --to-destination "$DEST_IP:$PORT" 2>/dev/null || true
            iptables -D FORWARD -p tcp -d "$DEST_IP" --dport "$PORT" -j ACCEPT 2>/dev/null || true
            ;;
        udp)
            iptables -t nat -D PREROUTING -d "$LOCAL_TS_IP" -p udp --dport "$PORT" -j DNAT --to-destination "$DEST_IP:$PORT" 2>/dev/null || true
            iptables -D FORWARD -p udp -d "$DEST_IP" --dport "$PORT" -j ACCEPT 2>/dev/null || true
            ;;
        both)
            remove_rule_specific "$PORT" tcp "$LOCAL_TS_IP"
            remove_rule_specific "$PORT" udp "$LOCAL_TS_IP"
            ;;
    esac

    netfilter-persistent save
    echo "=== Port forwarding rule removed ==="
}

remove_rule_specific() {
    local PORT="$1"
    local PROTO="$2"
    local LOCAL="$3"
    iptables -t nat -D PREROUTING -d "$LOCAL" -p "$PROTO" --dport "$PORT" -j DNAT --to-destination "$DEST_IP:$PORT" 2>/dev/null || true
    iptables -D FORWARD -p "$PROTO" -d "$DEST_IP" --dport "$PORT" -j ACCEPT 2>/dev/null || true
}

# Ensure dependencies are installed and IP forwarding enabled
install_requirements
enable_ip_forwarding

# Main menu loop
while true; do
    echo ""
    echo "==== Tailscale Port Forwarding Menu ===="
    echo "1) Install Tailscale"
    echo "2) Add new forwarding rule"
    echo "3) View current rules"
    echo "4) Remove a rule"
    echo "5) Exit"
    read -rp "Choose an option: " CHOICE

    case $CHOICE in
        1) install_tailscale ;;
        2) add_forward_rule ;;
        3) view_rules ;;
        4) remove_rule ;;
        5) exit 0 ;;
        *) echo "Invalid choice" ;;
    esac
done
