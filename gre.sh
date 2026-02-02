#!/bin/bash

# Coded By Arman & Un3

CYAN=$(tput setaf 6)
YELLOW=$(tput setaf 3)
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
RESET=$(tput sgr0)

echo -e "${CYAN}"
echo "===================================="
echo "     Coded By Arman & Un3"
echo "     GRE Multi-Tunnel Setup"
echo "===================================="
echo -e "${RESET}"

CONFIG_FILE="/etc/gre-tunnels.conf"
SERVICE_NAME="gre-multi-tunnel.service"
SCRIPT_PATH=$(realpath "$0")

# Function to apply all tunnels
apply_all() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "${RED}[!] Config not found: $CONFIG_FILE${RESET}"
        return 1
    fi

    # Clean old tunnels (optional - can be commented if you want persistence)
    ip link | grep gre-ir | awk '{print $2}' | cut -d: -f1 | xargs -I {} ip tunnel del {} 2>/dev/null

    source "$CONFIG_FILE"  # expects IRAN_IP=... and array-like FOREIGN_IPS=(ip1 ip2 ...)

    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    local idx=1
    for foreign_ip in "${FOREIGN_IPS[@]}"; do
        local tun="gre-ir${idx}"
        local local_tun_ip="132.168.30.$((idx*4+2))/30"   # .2, .6, .10, ...
        local remote_tun_ip="132.168.30.$((idx*4+1))"     # .1, .5, .9, ...

        echo "${YELLOW}[*] Setting up tunnel to $foreign_ip (${tun})${RESET}"

        ip tunnel add "$tun" mode gre local "$IRAN_IP" remote "$foreign_ip" ttl 255
        ip link set "$tun" up
        ip addr add "$local_tun_ip" dev "$tun"

        # Example NAT/MASQ rules - adjust as needed
        iptables -t nat -C POSTROUTING -o "$tun" -j MASQUERADE 2>/dev/null ||
            iptables -t nat -A POSTROUTING -o "$tun" -j MASQUERADE

        # Optional: route specific traffic or default via one of them
        # ip route add default via 132.168.30.1 dev gre-ir1 table main  (example)

        ((idx++))
    done

    echo "${GREEN}[+] All tunnels applied.${RESET}"
}

# Save config (append new foreign)
add_foreign() {
    read -p "Enter new FOREIGN server IP: " new_ip
    if [[ -z "$new_ip" ]]; then return; fi

    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        read -p "Enter IRAN public IP: " IRAN_IP
        echo "IRAN_IP=$IRAN_IP" > "$CONFIG_FILE"
        FOREIGN_IPS=()
    fi

    FOREIGN_IPS+=("$new_ip")
    printf "FOREIGN_IPS=(%s)\n" "${FOREIGN_IPS[*]}" >> "$CONFIG_FILE"
    echo "${GREEN}[+] Added $new_ip${RESET}"
}

# Uninstall / Cleanup
uninstall() {
    echo "${RED}Uninstalling GRE tunnels...${RESET}"

    # Stop & disable service
    systemctl disable --now "$SERVICE_NAME" 2>/dev/null
    rm -f /etc/systemd/system/"$SERVICE_NAME"

    # Delete tunnels
    ip link | grep gre-ir | awk '{print $2}' | cut -d: -f1 | xargs -I {} sh -c 'ip link set {} down; ip tunnel del {}' 2>/dev/null

    # Flush related iptables (careful - only example rules)
    iptables -t nat -D POSTROUTING -j MASQUERADE 2>/dev/null
    iptables -t nat -D PREROUTING -j DNAT --to-destination 132.168.30.1 2>/dev/null
    # Add more -D if you have specific rules

    rm -f "$CONFIG_FILE"
    systemctl daemon-reload

    echo "${GREEN}[+] Uninstall completed. Tunnels and service removed.${RESET}"
}

# ------------------ Main Menu ------------------
while true; do
    echo ""
    echo "1 - Install/Configure (Iran → Multi Foreign)"
    echo "2 - Add another Foreign server"
    echo "3 - Apply / Restart tunnels now"
    echo "4 - Add/Remove from Startup"
    echo "5 - Uninstall / Complete Cleanup"
    echo "6 - Exit"
    read -p "Choice: " opt

    case $opt in
        1)
            if [ -f "$CONFIG_FILE" ]; then
                echo "${YELLOW}Existing config found. You can add more foreign servers.${RESET}"
            else
                read -p "Iran public IP: " IRAN_IP
                echo "IRAN_IP=$IRAN_IP" > "$CONFIG_FILE"
                FOREIGN_IPS=()
            fi
            add_foreign
            apply_all
            ;;
        2)
            add_foreign
            apply_all
            ;;
        3)
            apply_all
            ;;
        4)
            if systemctl list-unit-files | grep -q "$SERVICE_NAME"; then
                read -p "Remove from startup? (y/n): " rem
                if [[ "$rem" =~ ^[Yy]$ ]]; then
                    systemctl disable --now "$SERVICE_NAME"
                    rm -f /etc/systemd/system/"$SERVICE_NAME"
                    systemctl daemon-reload
                    echo "${GREEN}Removed from startup.${RESET}"
                fi
            else
                cat <<EOF > /etc/systemd/system/"$SERVICE_NAME"
[Unit]
Description=Multi GRE Tunnel Setup
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
                systemctl enable "$SERVICE_NAME"
                systemctl start "$SERVICE_NAME" 2>/dev/null
                echo "${GREEN}Added to startup.${RESET}"
            fi
            ;;
        5)
            read -p "${RED}Are you sure? This removes ALL tunnels, rules and config! (y/N): ${RESET}" confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                uninstall
            fi
            ;;
        6) exit 0 ;;
        *) echo "Invalid choice" ;;
    esac
done
