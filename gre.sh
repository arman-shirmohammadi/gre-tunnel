#!/bin/bash

# Coded By Arman & Un3
# Multi GRE Tunnel - Iran to multiple Foreign servers

CYAN=$(tput setaf 6)
YELLOW=$(tput setaf 3)
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
RESET=$(tput sgr0)

echo -e "${CYAN}"
echo "===================================="
echo "     Coded By Arman & Un3"
echo "     GRE Multi-Tunnel Setup v2"
echo "===================================="
echo -e "${RESET}"

CONFIG_FILE="/etc/gre-tunnels.conf"
SERVICE_NAME="gre-multi-tunnel.service"
SCRIPT_PATH=$(realpath "$0" 2>/dev/null || echo "$0")

# Function: Clean specific tunnel interface
clean_tunnel() {
    local tun="$1"
    ip link set "${tun}" down 2>/dev/null
    ip tunnel del "${tun}" 2>/dev/null
}

# Function: Apply / recreate all tunnels
apply_all() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}[!] Config file not found: $CONFIG_FILE${RESET}"
        return 1
    fi

    source "$CONFIG_FILE"

    if [[ -z "$IRAN_IP" || ${#FOREIGN_IPS[@]} -eq 0 ]]; then
        echo -e "${RED}[!] IRAN_IP or FOREIGN_IPS missing in config${RESET}"
        return 1
    fi

    echo -e "${YELLOW}[*] Cleaning old tunnels and gre0 if exists...${RESET}"
    clean_tunnel "gre0"
    for i in {1..20}; do clean_tunnel "gre-ir${i}"; done

    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1

    local idx=1
    for foreign_ip in "${FOREIGN_IPS[@]}"; do
        local tun="gre-ir${idx}"
        local local_ip="132.168.30.$((idx*4 + 2))/30"
        local remote_ip="132.168.30.$((idx*4 + 1))"

        echo -e "${YELLOW}[*] Creating tunnel ${tun} → ${foreign_ip}${RESET}"

        clean_tunnel "${tun}"

        if ! ip tunnel add "${tun}" mode gre local "$IRAN_IP" remote "$foreign_ip" ttl 255; then
            echo -e "${RED}Failed to create tunnel ${tun}. Possible reasons:${RESET}"
            echo "  • Interface still exists (kernel/netlink cache)"
            echo "  • IP conflict or firewall blocking GRE (protocol 47)"
            echo "  • Kernel module ip_gre not loaded → try: modprobe ip_gre"
            echo -e "${YELLOW}Manual cleanup suggestion:${RESET} ip tunnel del ${tun} ; modprobe -r ip_gre ; modprobe ip_gre"
            return 1
        fi

        ip link set "${tun}" up mtu 1476
        ip addr add "${local_ip}" dev "${tun}"

        iptables -t nat -C POSTROUTING -o "${tun}" -j MASQUERADE 2>/dev/null ||
            iptables -t nat -A POSTROUTING -o "${tun}" -j MASQUERADE

        echo -e "${GREEN}  → Tunnel ${tun} created (local: ${local_ip%/*})${RESET}"
        ((idx++))
    done

    echo -e "${GREEN}\n[+] All tunnels applied successfully.${RESET}"
}

# Add new foreign server
add_foreign() {
    read -p "Enter new FOREIGN server IP: " new_ip
    [[ -z "$new_ip" ]] && return

    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        read -p "Enter IRAN public IP: " IRAN_IP
        echo "IRAN_IP=\"$IRAN_IP\"" > "$CONFIG_FILE"
        FOREIGN_IPS=()
    fi

    for existing in "${FOREIGN_IPS[@]}"; do
        if [[ "$existing" == "$new_ip" ]]; then
            echo -e "${YELLOW}[!] $new_ip is already in the list.${RESET}"
            return
        fi
    done

    FOREIGN_IPS+=("$new_ip")

    {
        echo "IRAN_IP=\"$IRAN_IP\""
        echo -n "FOREIGN_IPS=("
        printf "'%s' " "${FOREIGN_IPS[@]}"
        echo ")"
    } > "$CONFIG_FILE"

    echo -e "${GREEN}[+] Added $new_ip${RESET}"
}

# Full uninstall
uninstall() {
    echo -e "${RED}Uninstalling all GRE tunnels and related settings...${RESET}"

    systemctl disable --now "$SERVICE_NAME" 2>/dev/null
    rm -f /etc/systemd/system/"$SERVICE_NAME"*

    for i in {1..20}; do clean_tunnel "gre-ir${i}"; done
    clean_tunnel "gre0"

    iptables -t nat -D POSTROUTING -j MASQUERADE 2>/dev/null || true

    rm -f "$CONFIG_FILE"
    systemctl daemon-reload 2>/dev/null

    echo -e "${GREEN}[+] Cleanup finished.${RESET}"
}

# ────────────────────────────────────────────────
# Main Menu
# ────────────────────────────────────────────────

while true; do
    echo ""
    echo "1 = Install / Configure (set Iran IP + first Foreign)"
    echo "2 = Add another Foreign server"
    echo "3 = Apply / Recreate tunnels now"
    echo "4 = Add / Remove from Startup"
    echo "5 = Uninstall / Full Cleanup"
    echo "6 = Exit"
    read -p "Choice (1-6): " opt

    case $opt in
        1)
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
            if systemctl list-unit-files --type=service | grep -q "$SERVICE_NAME"; then
                read -p "Remove from startup? (y/n): " rem
                [[ "$rem" =~ ^[Yy]$ ]] && {
                    systemctl disable --now "$SERVICE_NAME"
                    rm -f /etc/systemd/system/"$SERVICE_NAME"
                    systemctl daemon-reload
                    echo -e "${GREEN}Removed from startup.${RESET}"
                }
            else
                cat <<EOF > /etc/systemd/system/"$SERVICE_NAME"
[Unit]
Description=Multi GRE Tunnel Auto Setup
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
                systemctl enable "$SERVICE_NAME" --now
                echo -e "${GREEN}Added to startup.${RESET}"
            fi
            ;;
        5)
            read -p "${RED}Are you sure? This removes ALL tunnels and config (y/N): ${RESET}" confirm
            [[ "$confirm" =~ ^[Yy]$ ]] && uninstall
            ;;
        6)
            echo "Exiting..."
            exit 0
            ;;
        *)
            echo "Invalid choice"
            ;;
    esac
done
