#!/bin/bash

CYAN=$(tput setaf 6)
YELLOW=$(tput setaf 3)
RESET=$(tput sgr0)

CONFIG_DIR="/etc/gre-tunnels"
SERVICE_FILE="/etc/systemd/system/gre-tunnels-restore.service"
STARTUP_SCRIPT="/etc/gre-tunnels/restore-gre-tunnels.sh"

[ ! -d "$CONFIG_DIR" ] && sudo mkdir -p "$CONFIG_DIR"

show_menu() {
    clear
    echo -e "${CYAN}"
    echo "===================================="
    echo " GRE Tunnel Setup Script"
    echo " Edited by Arman"
    echo "===================================="
    echo -e "${RESET}"
    echo ""
    echo " 1) Create new tunnel"
    echo " 2) Remove existing tunnel"
    echo " 3) List all tunnels"
    echo " 4) Apply / Persist tunnels (survive reboot)"
    echo " 5) Uninstall persistence"
    echo " 6) IP Changer (change IPs for existing tunnels)"
    echo " 7) Exit"
    echo ""
    read -p "Select option (1-7): " choice
}

create_tunnel() {
    echo ""
    echo "Creating new tunnel"
   
    echo -n "Tunnel name (example: gre-de1, gre-tr, ir-fr1): "
    read -r gre_name
   
    if [[ -z "$gre_name" || "$gre_name" =~ [[:space:]/] ]]; then
        echo "[!] Invalid name (no spaces or / allowed)."
        read -p "Press Enter to continue..."
        return
    fi
   
    if [ -f "$CONFIG_DIR/$gre_name" ]; then
        echo "[!] Tunnel with this name already exists."
        read -p "Press Enter to continue..."
        return
    fi
   
    echo ""
    echo "Your server location:"
    echo " 1 = IRAN side"
    echo " 2 = FOREIGN side"
    read -r LOCATION
   
    if [[ "$LOCATION" != "1" && "$LOCATION" != "2" ]]; then
        echo "[!] Only 1 or 2 allowed."
        read -p "Press Enter to continue..."
        return
    fi
   
    read -r -p "Iran public IP: " IP_IRAN
    read -r -p "Foreign public IP: " IP_FOREIGN
   
    while true; do
        echo -n "Subnet base for /30 (example: 10.70.70.0): "
        read -r input_subnet
        input_subnet=$(echo "$input_subnet" | xargs | tr -d '[:space:]')
        if [[ ! $input_subnet =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            echo "[!] Invalid IP format. Use four numbers separated by dots."
            continue
        fi
        IFS='.' read -r o1 o2 o3 o4 <<< "$input_subnet"
       
        for octet in "$o1" "$o2" "$o3" "$o4"; do
            if ! [[ "$octet" =~ ^[0-9]+$ ]] || (( octet < 0 || octet > 255 )); then
                echo "[!] Invalid octet: $octet (must be 0-255)"
                continue 2
            fi
        done
       
        subnet_base="${o1}.${o2}.${o3}.0"
        if [[ "$input_subnet" != "$subnet_base" ]]; then
            echo "[i] Corrected to network address: ${subnet_base}"
        fi
        break
    done
   
    foreign_ip="${o1}.${o2}.${o3}.1"
    iran_ip="${o1}.${o2}.${o3}.2"
    subnet="${subnet_base}/30"
   
    echo ""
    echo "Tunnel IPs will be:"
    echo " Iran side → ${iran_ip}"
    echo " Foreign side → ${foreign_ip}"
    echo " Subnet → ${subnet}"
    echo ""
   
    if [[ "$LOCATION" == "1" ]]; then
        local_public="$IP_IRAN"
        remote_public="$IP_FOREIGN"
        local_tun_ip="$iran_ip"
        remote_tun_ip="$foreign_ip"
       
        echo "[*] Configuring IRAN side..."
       
        sudo ip tunnel add "$gre_name" mode gre local "$local_public" remote "$remote_public" ttl 255 || { echo "[!] Failed to create tunnel"; read -p "Press Enter..."; return; }
        sudo ip link set "$gre_name" mtu 1476 up
        sudo ip addr add "${local_tun_ip}/30" dev "$gre_name"
       
        sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
        grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf >/dev/null
       
        sudo iptables -t mangle -A POSTROUTING -o "$gre_name" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1380 2>/dev/null
        sudo iptables -t nat -A PREROUTING -p tcp --dport 22 -j DNAT --to-destination "$local_tun_ip" 2>/dev/null
        sudo iptables -t nat -C PREROUTING -j DNAT --to-destination "$remote_tun_ip" 2>/dev/null || \
            sudo iptables -t nat -A PREROUTING -j DNAT --to-destination "$remote_tun_ip" 2>/dev/null
        sudo iptables -t nat -A POSTROUTING -o "$gre_name" -j MASQUERADE 2>/dev/null
    else
        local_public="$IP_FOREIGN"
        remote_public="$IP_IRAN"
        local_tun_ip="$foreign_ip"
        remote_tun_ip="$iran_ip"
       
        echo "[*] Configuring FOREIGN side..."
       
        sudo ip tunnel add "$gre_name" mode gre local "$local_public" remote "$remote_public" ttl 255 || { echo "[!] Failed to create tunnel"; read -p "Press Enter..."; return; }
        sudo ip link set "$gre_name" mtu 1476 up
        sudo ip addr add "${local_tun_ip}/30" dev "$gre_name"
       
        sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
        grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf >/dev/null
       
        sudo iptables -t nat -A POSTROUTING -s "$subnet" -j MASQUERADE 2>/dev/null
        sudo iptables -C INPUT -p icmp -j DROP 2>/dev/null || sudo iptables -A INPUT -p icmp -j DROP 2>/dev/null
    fi
   
    cat > "$CONFIG_DIR/$gre_name" <<EOF
LOCATION=$LOCATION
IP_IRAN=$IP_IRAN
IP_FOREIGN=$IP_FOREIGN
SUBNET_BASE=$subnet_base
GRE_NAME=$gre_name
EOF
   
    echo ""
    echo "Tunnel '$gre_name' created successfully."
    echo "Tunnel IPs → $iran_ip (IRAN) ↔ $foreign_ip (FOREIGN)"
    echo ""
    read -p "Press Enter to return to menu..."
}

remove_tunnel() {
    echo ""
    echo "Remove tunnel"
    echo "Existing tunnels:"
    ls -1 "$CONFIG_DIR" 2>/dev/null || echo "(no tunnels found)"
    echo ""
    read -r -p "Tunnel name to remove: " gre_name
   
    if [ ! -f "$CONFIG_DIR/$gre_name" ]; then
        echo "[!] Tunnel '$gre_name' not found."
        read -p "Press Enter..."
        return
    fi
   
    source "$CONFIG_DIR/$gre_name"
   
    foreign_ip="${SUBNET_BASE%.*}.1"
    iran_ip="${SUBNET_BASE%.*}.2"
    subnet="${SUBNET_BASE}/30"
   
    echo "[!] WARNING: Removing this tunnel may break SSH access if it's the only tunnel!"
    echo "     Make sure you have console access or another way in."
    read -p "Continue? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Cancelled."
        read -p "Press Enter..."
        return
    fi
   
    # بک‌آپ سریع از iptables قبل حذف
    sudo iptables-save > "/tmp/iptables-backup-before-remove-$(date +%s).txt" 2>/dev/null
    echo "[i] iptables backup saved to /tmp/iptables-backup-before-remove-*.txt"
   
    if [[ "$LOCATION" == "1" ]]; then
        local_tun_ip="$iran_ip"
        remote_tun_ip="$foreign_ip"
        sudo iptables -t mangle -D POSTROUTING -o "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1380 2>/dev/null
        sudo iptables -t nat -D PREROUTING -p tcp --dport 22 -j DNAT --to-destination "$local_tun_ip" 2>/dev/null
        sudo iptables -t nat -D POSTROUTING -o "$GRE_NAME" -j MASQUERADE 2>/dev/null
       
        other_iran=$(ls "$CONFIG_DIR" 2>/dev/null | grep -v "^$gre_name$" | xargs -I {} bash -c 'source "$CONFIG_DIR/{}"; [[ $LOCATION == 1 ]] && echo 1' | wc -l)
        if [[ $other_iran -eq 0 ]]; then
            sudo iptables -t nat -D PREROUTING -j DNAT --to-destination "$remote_tun_ip" 2>/dev/null
            # اضافه کردن قانون ایمن برای SSH به IP محلی (جلوگیری از قطع کامل دسترسی)
            sudo iptables -t nat -A PREROUTING -p tcp --dport 22 -j DNAT --to-destination 127.0.0.1:22 2>/dev/null || true
            echo "[i] Added fallback SSH rule to localhost to prevent lockout."
        fi
    else
        sudo iptables -t nat -D POSTROUTING -s "$subnet" -j MASQUERADE 2>/dev/null
        if [ -z "$(ls -A "$CONFIG_DIR" 2>/dev/null | grep -v "^$gre_name$")" ]; then
            sudo iptables -D INPUT -p icmp -j DROP 2>/dev/null
        fi
    fi
   
    sudo ip addr del "${local_tun_ip}/30" dev "$GRE_NAME" 2>/dev/null
    sudo ip link set "$GRE_NAME" down 2>/dev/null
    sudo ip tunnel del "$GRE_NAME" 2>/dev/null
   
    rm -f "$CONFIG_DIR/$gre_name"
   
    echo "Tunnel '$gre_name' removed safely."
    echo "If SSH is still cut, use console to restore iptables backup:"
    echo "  sudo iptables-restore < /tmp/iptables-backup-before-remove-*.txt"
    read -p "Press Enter to continue..."
}

list_tunnels() {
    echo ""
    echo "Configured tunnels:"
    if [ ! "$(ls -A "$CONFIG_DIR" 2>/dev/null)" ]; then
        echo " No tunnels found."
    else
        for f in "$CONFIG_DIR"/*; do
            source "$f"
            echo ""
            echo " Tunnel name : $GRE_NAME"
            echo " Location : $( [[ $LOCATION == 1 ]] && echo IRAN || echo FOREIGN )"
            echo " Iran IP : $IP_IRAN"
            echo " Foreign IP : $IP_FOREIGN"
            echo " Subnet : ${SUBNET_BASE}/30"
            echo " Tunnel IPs : ${SUBNET_BASE%.*}.2 (IR) ↔ ${SUBNET_BASE%.*}.1 (Foreign)"
            echo " ────────────────────────────────"
        done
    fi
    echo ""
    read -p "Press Enter to return..."
}

persist_all() {
    echo ""
    echo "[*] Setting up persistence for multiple tunnels..."
   
    echo "  Creating startup script..."
    cat > "$STARTUP_SCRIPT" <<'EOL'
#!/bin/bash

sysctl -w net.ipv4.ip_forward=1 2>/dev/null

for conf in /etc/gre-tunnels/*; do
    [ -f "$conf" ] || continue
    source "$conf"
   
    foreign_ip="${SUBNET_BASE%.*}.1"
    iran_ip="${SUBNET_BASE%.*}.2"
   
    if [[ "$LOCATION" == "1" ]]; then
        ip tunnel add "$GRE_NAME" mode gre local "$IP_IRAN" remote "$IP_FOREIGN" ttl 255 2>/dev/null || true
        ip link set "$GRE_NAME" mtu 1476 up 2>/dev/null || true
        ip addr add "${iran_ip}/30" dev "$GRE_NAME" 2>/dev/null || true
       
        iptables -t mangle -A POSTROUTING -o "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1380 2>/dev/null || true
        iptables -t nat -A PREROUTING -p tcp --dport 22 -j DNAT --to-destination "$iran_ip" 2>/dev/null || true
        iptables -t nat -A POSTROUTING -o "$GRE_NAME" -j MASQUERADE 2>/dev/null || true
       
        iptables -t nat -C PREROUTING -j DNAT --to-destination "$foreign_ip" 2>/dev/null || \
            iptables -t nat -A PREROUTING -j DNAT --to-destination "$foreign_ip" 2>/dev/null || true
    else
        ip tunnel add "$GRE_NAME" mode gre local "$IP_FOREIGN" remote "$IP_IRAN" ttl 255 2>/dev/null || true
        ip link set "$GRE_NAME" mtu 1476 up 2>/dev/null || true
        ip addr add "${foreign_ip}/30" dev "$GRE_NAME" 2>/dev/null || true
       
        iptables -t nat -A POSTROUTING -s "${SUBNET_BASE}.0/30" -j MASQUERADE 2>/dev/null || true
        iptables -A INPUT -p icmp -j DROP 2>/dev/null || true
    fi
done
EOL
   
    sudo chmod +x "$STARTUP_SCRIPT" && echo "  Startup script created."
   
    echo "  Creating systemd service..."
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Restore all GRE tunnels and iptables rules after boot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$STARTUP_SCRIPT
Restart=on-failure
StandardOutput=append:/var/log/gre-tunnels.log
StandardError=append:/var/log/gre-tunnels.log

[Install]
WantedBy=multi-user.target
EOF
   
    echo "  Reloading systemd..."
    sudo systemctl daemon-reload && echo "  Systemd reloaded."
   
    echo "  Enabling service..."
    sudo systemctl enable gre-tunnels-restore.service 2>/dev/null && echo "  Service enabled."
   
    echo "  Starting service in background (instant return)..."
    sudo systemctl start gre-tunnels-restore.service 2>/dev/null &
   
    echo ""
    echo "Persistence setup completed instantly."
    echo "Service started in background (no wait)."
    echo ""
    echo "Check status anytime:"
    echo "  sudo systemctl status gre-tunnels-restore.service -l"
    echo "  tail -n 50 /var/log/gre-tunnels.log"
    echo ""
    read -p "Press Enter to return to menu..."
}

uninstall_persistence() {
    echo ""
    echo "[*] Uninstalling persistence..."
   
    if [ -f "$SERVICE_FILE" ]; then
        sudo systemctl disable gre-tunnels-restore.service 2>/dev/null
        sudo systemctl stop gre-tunnels-restore.service 2>/dev/null
        sudo rm -f "$SERVICE_FILE"
        echo "  Service removed."
    fi
   
    if [ -f "$STARTUP_SCRIPT" ]; then
        sudo rm -f "$STARTUP_SCRIPT"
        echo "  Startup script removed."
    fi
   
    sudo systemctl daemon-reload 2>/dev/null
   
    echo ""
    echo "Persistence removed."
    read -p "Press Enter to continue..."
}

ip_changer() {
    echo ""
    echo "IP Changer - Change Iran/Foreign IPs for existing tunnels"
    echo "----------------------------------------------------------"
   
    if [ ! "$(ls -A "$CONFIG_DIR" 2>/dev/null)" ]; then
        echo " No tunnels found."
        read -p "Press Enter to return..."
        return
    fi
   
    echo "Available tunnels:"
    i=1
    declare -A tunnel_map
    for f in "$CONFIG_DIR"/*; do
        GRE_NAME=$(grep '^GRE_NAME=' "$f" | cut -d= -f2-)
        IP_IRAN=$(grep '^IP_IRAN=' "$f" | cut -d= -f2-)
        IP_FOREIGN=$(grep '^IP_FOREIGN=' "$f" | cut -d= -f2-)
        SUBNET_BASE=$(grep '^SUBNET_BASE=' "$f" | cut -d= -f2-)
       
        if [[ -n "$GRE_NAME" && -n "$IP_IRAN" && -n "$IP_FOREIGN" ]]; then
            echo "  $i) $GRE_NAME   |  Iran: $IP_IRAN   |  Foreign: $IP_FOREIGN"
            tunnel_map[$i]="$f"
            ((i++))
        fi
    done
   
    if [ ${#tunnel_map[@]} -eq 0 ]; then
        echo " No valid tunnels found."
        read -p "Press Enter to return..."
        return
    fi
   
    read -p "Select tunnel number to change (or 0 to cancel): " sel
   
    if [[ "$sel" == "0" || ! "$sel" =~ ^[0-9]+$ || "$sel" -lt 1 || "$sel" -gt ${#tunnel_map[@]} ]]; then
        echo "Cancelled."
        read -p "Press Enter to return..."
        return
    fi
   
    selected_file="${tunnel_map[$sel]}"
    source "$selected_file"
   
    echo ""
    echo "Current IPs for $GRE_NAME:"
    echo "  Iran IP   : $IP_IRAN"
    echo "  Foreign IP: $IP_FOREIGN"
   
    read -r -p "New Iran IP (leave empty to keep current): " new_iran
    read -r -p "New Foreign IP (leave empty to keep current): " new_foreign
   
    if [[ -n "$new_iran" ]]; then
        IP_IRAN="$new_iran"
    fi
   
    if [[ -n "$new_foreign" ]]; then
        IP_FOREIGN="$new_foreign"
    fi
   
    cat > "$selected_file" <<EOF
LOCATION=$LOCATION
IP_IRAN=$IP_IRAN
IP_FOREIGN=$IP_FOREIGN
SUBNET_BASE=$SUBNET_BASE
GRE_NAME=$GRE_NAME
EOF
   
    echo ""
    echo "IPs updated successfully for $GRE_NAME"
    echo "New values:"
    echo "  Iran IP   : $IP_IRAN"
    echo "  Foreign IP: $IP_FOREIGN"
    echo ""
    echo "Note: Changes are only in config file."
    echo "To apply immediately: remove and recreate the tunnel."
    echo "On next reboot (if persistence active): will use new IPs."
   
    if sudo systemctl is-active --quiet gre-tunnels-restore.service; then
        echo "  Restarting persistence service..."
        sudo systemctl restart gre-tunnels-restore.service 2>/dev/null &
    fi
   
    read -p "Press Enter to return..."
}

while true; do
    show_menu
    case $choice in
        1) create_tunnel ;;
        2) remove_tunnel ;;
        3) list_tunnels ;;
        4) persist_all ;;
        5) uninstall_persistence ;;
        6) ip_changer ;;
        7) echo -e "\nGoodbye.\n"; exit 0 ;;
        *) echo "[!] Invalid choice. Select 1-7."
           read -p "Press Enter..." ;;
    esac
done
