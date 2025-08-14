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
    apt-get install -y iptables iptables-persistent netfilter-persistent
}

enable_ip_forwarding() {
    echo "=== Enabling IP forwarding ==="
    sysctl -w net.ipv4.ip_forward=1
    grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
}

add_forward_rule() {
    read -rp "Enter Remote Server Tailscale IP: " REMOTE_IP
    read -rp "Enter ports to forward (comma-separated or ranges, e.g. 22,80,8000-8010): " PORTS

    IFS=',' read -ra PORT_ARRAY <<< "$PORTS"
    for port in "${PORT_ARRAY[@]}"; do
        if [[ "$port" == *"-"* ]]; then
            start=$(echo "$port" | cut -d'-' -f1)
            end=$(echo "$port" | cut -d'-' -f2)
            for ((p=start; p<=end; p++)); do
                echo "Forwarding port $p → $REMOTE_IP:$p"
                iptables -t nat -A PREROUTING -p tcp --dport "$p" -j DNAT --to-destination "$REMOTE_IP:$p"
                iptables -A FORWARD -p tcp -d "$REMOTE_IP" --dport "$p" -j ACCEPT
                iptables -t nat -A POSTROUTING -p tcp -d "$REMOTE_IP" --dport "$p" -j MASQUERADE
            done
        else
            echo "Forwarding port $port → $REMOTE_IP:$port"
            iptables -t nat -A PREROUTING -p tcp --dport "$port" -j DNAT --to-destination "$REMOTE_IP:$port"
            iptables -A FORWARD -p tcp -d "$REMOTE_IP" --dport "$port" -j ACCEPT
            iptables -t nat -A POSTROUTING -p tcp -d "$REMOTE_IP" --dport "$port" -j MASQUERADE
        fi
    done

    netfilter-persistent save
    echo "=== Port forwarding rules added and saved ==="
}

view_rules() {
    echo "=== NAT PREROUTING Rules ==="
    iptables -t nat -L PREROUTING -n -v
    echo ""
    echo "=== FORWARD Rules ==="
    iptables -L FORWARD -n -v
    echo ""
    echo "=== NAT POSTROUTING Rules ==="
    iptables -t nat -L POSTROUTING -n -v
}

delete_all_rules() {
    echo "=== Deleting all port forwarding rules ==="
    iptables -t nat -F PREROUTING
    iptables -t nat -F POSTROUTING
    iptables -F FORWARD
    netfilter-persistent save
    echo "=== All forwarding rules deleted ==="
}

# Ensure dependencies and IP forwarding
install_requirements
enable_ip_forwarding

# Menu loop
while true; do
    echo ""
    echo "==== VPN Server Port Forwarding Menu ===="
    echo "1) Add new forwarding rule"
    echo "2) View current rules"
    echo "3) Delete all rules"
    echo "4) Exit"
    read -rp "Choose an option: " CHOICE

    case $CHOICE in
        1) add_forward_rule ;;
        2) view_rules ;;
        3) delete_all_rules ;;
        4) exit 0 ;;
        *) echo "Invalid choice" ;;
    esac
done
