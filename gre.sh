#!/bin/bash

# Coded By Arman & Un3

CYAN=$(tput setaf 6)
YELLOW=$(tput setaf 3)
RESET=$(tput sgr0)

echo -e "${CYAN}"
echo "===================================="
echo "     Coded By Arman & Un3"
echo "     GRE Tunnel Setup Script"
echo "===================================="
echo -e "${RESET}"

# Function to apply configuration (used by systemd service too)
apply_config() {
    if [ ! -f /etc/gre-tunnel.conf ]; then
        echo "[!] Config file not found: /etc/gre-tunnel.conf"
        exit 1
    fi

    source /etc/gre-tunnel.conf

    # Clean up existing tunnel if exists
    ip tunnel del vatan-m2 2>/dev/null
    ip link set vatan-m2 down 2>/dev/null

    if [[ "$LOCATION" == "1" ]]; then
        echo "[*] Applying config for IRAN server..."

        ip tunnel add vatan-m2 mode gre local "$IP_IRAN" remote "$IP_FOREIGN" ttl 255
        ip link set vatan-m2 up
        ip addr add 132.168.30.2/30 dev vatan-m2

        sysctl -w net.ipv4.ip_forward=1

        # Apply iptables rules only if not already present
        iptables -t nat -C PREROUTING -p tcp --dport 22 -j DNAT --to-destination 132.168.30.2 2>/dev/null ||
            iptables -t nat -A PREROUTING -p tcp --dport 22 -j DNAT --to-destination 132.168.30.2

        iptables -t nat -C PREROUTING -j DNAT --to-destination 132.168.30.1 2>/dev/null ||
            iptables -t nat -A PREROUTING -j DNAT --to-destination 132.168.30.1

        iptables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null ||
            iptables -t nat -A POSTROUTING -j MASQUERADE

    elif [[ "$LOCATION" == "2" ]]; then
        echo "[*] Applying config for FOREIGN server..."

        ip tunnel add vatan-m2 mode gre local "$IP_FOREIGN" remote "$IP_IRAN" ttl 255
        ip link set vatan-m2 up
        ip addr add 132.168.30.1/30 dev vatan-m2

        iptables -C INPUT --proto icmp -j DROP 2>/dev/null ||
            iptables -A INPUT --proto icmp -j DROP

    else
        echo "[!] Invalid location in config."
        exit 1
    fi

    echo "[+] Configuration applied successfully."
}

# Check if running in --apply mode (for systemd service)
if [[ "$1" == "--apply" ]]; then
    apply_config
    exit 0
fi

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "[!] Please run as root (sudo)."
    exit 1
fi

# Main menu loop
while true; do
    echo ""
    echo "Select an option:"
    echo "1 - Install / Configure GRE Tunnel"
    echo "2 - Remove from Startup"
    echo "3 - Exit"
    read -p "Enter choice (1-3): " choice

    case $choice in
        1)
            echo ""
            echo "Select server location:"
            echo "1 - IRAN"
            echo "2 - FOREIGN"
            read -p "Enter 1 or 2: " LOCATION

            if [[ "$LOCATION" != "1" && "$LOCATION" != "2" ]]; then
                echo "[!] Invalid selection."
                continue
            fi

            read -p "Enter IRAN server IP: " IP_IRAN
            read -p "Enter FOREIGN server IP: " IP_FOREIGN

            # Save config
            cat <<EOF > /etc/gre-tunnel.conf
LOCATION=$LOCATION
IP_IRAN=$IP_IRAN
IP_FOREIGN=$IP_FOREIGN
EOF

            # Apply now
            apply_config

            # Ask for startup
            echo ""
            read -p "Do you want to add this to startup (run on boot)? (y/n): " add_startup
            if [[ "$add_startup" =~ ^[Yy]$ ]]; then
                SCRIPT_PATH=$(realpath "$0")

                cat <<EOF > /etc/systemd/system/gre-tunnel.service
[Unit]
Description=GRE Tunnel Auto Setup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH --apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

                systemctl daemon-reload
                systemctl enable gre-tunnel.service
                systemctl start gre-tunnel.service 2>/dev/null
                echo "[+] Added to startup. Service: gre-tunnel.service"
            fi
            ;;

        2)
            if [ -f /etc/systemd/system/gre-tunnel.service ]; then
                systemctl disable gre-tunnel.service
                systemctl stop gre-tunnel.service 2>/dev/null
                rm -f /etc/systemd/system/gre-tunnel.service
                systemctl daemon-reload
                echo "[+] Removed from startup."
            else
                echo "[!] No startup service found."
            fi
            ;;

        3)
            echo "Exiting..."
            exit 0
            ;;

        *)
            echo "[!] Invalid choice. Try again."
            ;;
    esac
done
