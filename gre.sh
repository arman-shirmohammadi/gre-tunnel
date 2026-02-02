#!/bin/bash
#
# Coded by Arman & Un3
#

SERVICE_NAME="gre-tunnel-manager.service"
SCRIPT_PATH="/usr/local/bin/gre-manager.sh"

function header() {
    clear
    echo "===================================="
    echo "    GRE Tunnel Manager v1"
    echo "     Coded by Arman & Un3"
    echo "===================================="
}

function list_tunnels() {
    echo "Existing GRE tunnels:"
    ip -details link show type gre | grep -E "gre|GRE"
}

function create_tunnel() {
    read -p "Enter name for GRE interface (e.g. gre0): " TUN
    read -p "Local IP: " LOCAL
    read -p "Remote IP: " REMOTE
    read -p "Assign GRE IP/30 range (local-side): " GREIP

    # Remove existing if exists
    ip tunnel show | grep -q "$TUN" && {
        echo "[!] Tunnel $TUN exists — removing..."
        sudo ip tunnel del "$TUN"
    }

    echo "[*] Creating GRE tunnel..."
    sudo ip tunnel add "$TUN" mode gre local "$LOCAL" remote "$REMOTE" ttl 255
    sudo ip addr add "$GREIP" dev "$TUN"
    sudo ip link set "$TUN" up

    echo "[+] Tunnel $TUN created."
}

function enable_service() {
    sudo bash -c "cat > /etc/systemd/system/$SERVICE_NAME <<EOF
[Unit]
Description=GRE Tunnel Manager Service
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash $SCRIPT_PATH auto
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF"

    sudo systemctl daemon-reload
    sudo systemctl enable "$SERVICE_NAME"
    echo "[+] Service enabled."
}

function remove_service() {
    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null
    sudo rm /etc/systemd/system/"$SERVICE_NAME" 2>/dev/null
    sudo systemctl daemon-reload
    echo "[+] Service removed."
}

function uninstall_all() {
    echo "[!] Removing all GRE tunnels..."
    ip tunnel show | awk '{print $1}' | while read TUNL; do
        sudo ip tunnel del "$TUNL"
    done
    remove_service
    echo "[+] Uninstall completed."
}

function main_menu() {
    header
    echo "1) Install & Configure GRE Tunnel"
    echo "2) Enable Service (Auto Start on Boot)"
    echo "3) Remove from Service"
    echo "4) Uninstall (remove tunnels & cleanup)"
    echo "5) Show GRE Tunnels"
    echo "6) Exit"
    echo "----------------------------------"
    read -p "Choose an option: " CHOICE

    case "$CHOICE" in
        1) create_tunnel ;;
        2) enable_service ;;
        3) remove_service ;;
        4) uninstall_all ;;
        5) list_tunnels ;;
        6) exit 0 ;;
        *) echo "Invalid option." ;;
    esac
    read -p "Press Enter to continue..."
    main_menu
}

# Auto-run from service
if [[ "$1" == "auto" ]]; then
    header
    create_tunnel
    exit 0
fi

main_menu
