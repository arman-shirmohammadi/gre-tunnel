#!/bin/bash
#
# ====================================
#   GRE Tunnel Manager
#   Coded by Arman & Un3
#   Fixed & Improved: root check + auto GRE IP + gre0 protection
# ====================================
#

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "[!] This script must be run as root. Elevating privileges..."
    exec sudo "$0" "$@"
    exit 1
fi

SERVICE_NAME="gre-tunnel-manager.service"
SCRIPT_PATH="/usr/local/bin/gre.sh"

# ---------- UI ----------
header() {
    clear
    echo "===================================="
    echo "        GRE Tunnel Manager"
    echo "       Coded by Arman & Un3"
    echo "===================================="
    echo
}

pause() {
    read -p "Press Enter to continue..."
}

# ---------- FUNCTIONS ----------

list_tunnels() {
    echo "[*] Existing GRE tunnels:"
    echo "------------------------------------"
    if ip -o tunnel show | grep -q gre; then
        ip -o tunnel show
    else
        echo "No GRE tunnels found."
    fi
    echo
}

create_tunnel() {
    echo "[*] Create new GRE tunnel"
    echo "------------------------------------"

    read -p "GRE interface name (e.g. gre1, gre2 – gre0 forbidden!): " TUN
    if [[ "$TUN" == "gre0" ]]; then
        echo "[!] Error: 'gre0' is a reserved fallback interface and cannot be deleted or recreated."
        echo "    Choose a different name like gre1, gre-mytunnel, tunnel1, etc."
        pause
        return
    fi

    read -p "Local public IP: " LOCAL
    read -p "Remote public IP: " REMOTE

    # اتوماتیک ست کردن آدرس داخل تونل
    GREIP="192.168.10.1/30"
    REMOTE_GREIP="192.168.10.2/30"

    echo "[i] Local tunnel IP   : $GREIP"
    echo "[i] Remote should use : $REMOTE_GREIP"
    echo

    if ip tunnel show | grep -qw "$TUN"; then
        echo "[!] Tunnel $TUN already exists — removing it first"
        sudo ip tunnel del "$TUN" 2>/dev/null || echo "[!] Delete failed (possibly in use or protected)"
    fi

    echo "[*] Creating tunnel..."
    sudo ip tunnel add "$TUN" mode gre local "$LOCAL" remote "$REMOTE" ttl 255 || { echo "[!] Failed to add tunnel"; pause; return; }
    sudo ip addr add "$GREIP" dev "$TUN" || { echo "[!] Failed to add IP"; pause; return; }
    sudo ip link set "$TUN" up || { echo "[!] Failed to bring up interface"; pause; return; }

    echo "[+] Tunnel $TUN created successfully"
    echo "    Local  IP inside tunnel: $GREIP"
    echo "    Remote IP inside tunnel: $REMOTE_GREIP (set this on the other side)"
    echo
}

enable_service() {
    echo "[*] Enabling startup service..."

    sudo cp "$0" "$SCRIPT_PATH"
    sudo chmod +x "$SCRIPT_PATH"

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
    sudo systemctl enable "$SERVICE_NAME" 2>/dev/null

    echo "[+] Service enabled (runs on boot - note: currently only placeholder)"
    echo
}

remove_service() {
    echo "[*] Removing startup service..."

    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null
    sudo rm -f /etc/systemd/system/"$SERVICE_NAME"
    sudo systemctl daemon-reload

    echo "[+] Service removed"
    echo
}

uninstall_all() {
    echo "[!] Removing ALL GRE tunnels (except reserved gre0)"
    echo "------------------------------------"

    for TUN in $(ip -o tunnel show | grep -v "gre0@" | grep gre | awk -F': ' '{print $2}' | awk '{print $1}'); do
        echo "Removing $TUN ..."
        sudo ip tunnel del "$TUN" 2>/dev/null || echo "[!] Failed to remove $TUN"
    done

    remove_service

    echo "[+] Uninstall completed"
    echo
}

# ---------- AUTO MODE (for systemd) ----------
if [[ "$1" == "auto" ]]; then
    # اینجا می‌تونی بعداً منطق ساخت تونل ثابت رو بذاری اگر خواستی persist بشه
    exit 0
fi

# ---------- MENU ----------
while true; do
    header
    echo "1) Create GRE Tunnel"
    echo "2) Enable Startup Service"
    echo "3) Remove from Startup"
    echo "4) Uninstall (Remove all GRE tunnels)"
    echo "5) List GRE Tunnels"
    echo "6) Exit"
    echo "------------------------------------"
    read -p "Choose an option: " CHOICE
    echo

    case "$CHOICE" in
        1) create_tunnel; pause ;;
        2) enable_service; pause ;;
        3) remove_service; pause ;;
        4) uninstall_all; pause ;;
        5) list_tunnels; pause ;;
        6) echo "Goodbye!"; exit 0 ;;
        *) echo "Invalid option"; pause ;;
    esac
done
