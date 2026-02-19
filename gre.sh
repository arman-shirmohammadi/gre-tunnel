#!/usr/bin/env bash
set -e
# ================================================
#        Coded by arman
#        GRE Multi Tunnel Manager
# ================================================

GRE_DIR="/etc/gre-tunnels"
mkdir -p "$GRE_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

IPTABLES_RULES="/etc/iptables.rules"

# Ask server type only once
if [ ! -f "$GRE_DIR/server_type" ]; then
    echo -e "${GREEN}Which server is this?${NC}"
    echo "1 = Iran"
    echo "2 = Foreign"
    read -rp "Choice (1 or 2): " server_choice

    if [[ "$server_choice" == "1" ]]; then
        echo "iran" > "$GRE_DIR/server_type"
    elif [[ "$server_choice" == "2" ]]; then
        echo "foreign" > "$GRE_DIR/server_type"
    else
        echo -e "${RED}Invalid choice. Exiting...${NC}"
        exit 1
    fi
fi

SERVER_TYPE=$(cat "$GRE_DIR/server_type")

show_list() {
    if [ ! -s "$GRE_DIR/tunnels.list" ]; then
        echo "No tunnels defined."
        return
    fi

    echo -e "\n${YELLOW}Current tunnels:${NC}"
    printf "%-5s %-18s %-18s %-15s %-15s\n" "ID" "Name" "Iran IP" "Foreign IP" "This Tunnel IP" "Peer Tunnel IP"
    echo "-----------------------------------------------------------------------"
    i=1
    while IFS='|' read -r name iran_ip foreign_ip this_tun_ip; do
        [ -z "$name" ] && continue
        peer_tun_ip="${this_tun_ip%.2}.1"
        [ "$SERVER_TYPE" = "foreign" ] && peer_tun_ip="${this_tun_ip%.1}.2"
        printf "%-5s %-18s %-18s %-18s %-15s %-15s\n" "$i" "$name" "$iran_ip" "$foreign_ip" "$this_tun_ip" "$peer_tun_ip"
        ((i++))
    done < "$GRE_DIR/tunnels.list"
    echo ""
}

add_tunnel() {
    echo -e "\n${GREEN}Add new tunnel${NC}"

    read -rp "Tunnel name (e.g. node1, fra1): " TUN_NAME
    TUN_NAME=$(echo "$TUN_NAME" | tr -s ' ' '_' | tr -cd '[:alnum:]_-')
    [ -z "$TUN_NAME" ] && { echo -e "${RED}Name cannot be empty${NC}"; return; }

    grep -q "^$TUN_NAME|" "$GRE_DIR/tunnels.list" 2>/dev/null && {
        echo -e "${RED}Name already used${NC}"
        return
    }

    read -rp "Iran IP: " IRAN_IP
    [[ ! $IRAN_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && {
        echo -e "${RED}Invalid Iran IP${NC}"
        return
    }

    read -rp "Foreign IP: " FOREIGN_IP
    [[ ! $FOREIGN_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && {
        echo -e "${RED}Invalid Foreign IP${NC}"
        return
    }

    read -rp "Tunnel subnet base (must end with .0, e.g. 10.116.70.0): " SUBNET_BASE
    [[ ! $SUBNET_BASE =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.0$ ]] && {
        echo -e "${RED}Must end with .0${NC}"
        return
    }

    BASE_PREFIX="${SUBNET_BASE%.0}"

    if [ "$SERVER_TYPE" = "iran" ]; then
        TUN_LOCAL="${BASE_PREFIX}.2"
        TUN_PEER="${BASE_PREFIX}.1"
        THIS_IP="$IRAN_IP"
        PEER_IP="$FOREIGN_IP"
    else
        TUN_LOCAL="${BASE_PREFIX}.1"
        TUN_PEER="${BASE_PREFIX}.2"
        THIS_IP="$FOREIGN_IP"
        PEER_IP="$IRAN_IP"
    fi

    GRE_DEV="gre-${TUN_NAME}"

    if ip link show "$GRE_DEV" &>/dev/null; then
        echo -e "${YELLOW}Interface $GRE_DEV exists. Deleting...${NC}"
        ip link delete "$GRE_DEV" 2>/dev/null || true
    fi

    ip tunnel add "$GRE_DEV" mode gre local "$THIS_IP" remote "$PEER_IP" ttl 255 || {
        echo -e "${RED}Failed to add tunnel${NC}"
        return
    }

    ip link set "$GRE_DEV" up
    ip addr add "${TUN_LOCAL}/30" dev "$GRE_DEV"

    echo "${TUN_NAME}|${IRAN_IP}|${FOREIGN_IP}|${TUN_LOCAL}" >> "$GRE_DIR/tunnels.list"

    echo -e "\n${GREEN}Tunnel $TUN_NAME created${NC}"
    echo -e "  Interface → $GRE_DEV"
    echo -e "  This IP   → $TUN_LOCAL"
    echo -e "  Peer IP   → $TUN_PEER"

    if [ "$SERVER_TYPE" = "iran" ]; then
        echo -e "\n${YELLOW}Applying iptables rules (global)${NC}"
        iptables -t nat -A POSTROUTING -j MASQUERADE
        iptables -t nat -A PREROUTING -p tcp --dport 22 -j DNAT --to-destination "$TUN_LOCAL"
        iptables -t nat -A PREROUTING -j DNAT --to-destination "$TUN_PEER"
        echo 1 > /proc/sys/net/ipv4/ip_forward
        grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p >/dev/null
        iptables-save > "$IPTABLES_RULES"
    fi

    echo -e "\n${GREEN}Test:${NC} ping $TUN_PEER"
}

remove_tunnel() {
    show_list
    [ ! -s "$GRE_DIR/tunnels.list" ] && return

    read -rp "ID to remove (0 = cancel): " choice
    [[ ! $choice =~ ^[0-9]+$ || $choice -eq 0 ]] && { echo "Cancelled"; return; }

    line=$(sed -n "${choice}p" "$GRE_DIR/tunnels.list")
    [ -z "$line" ] && { echo -e "${RED}Invalid ID${NC}"; return; }

    IFS='|' read -r name iran_ip foreign_ip local_ip <<< "$line"
    dev="gre-${name}"
    peer_tun_ip="${local_ip%.2}.1"
    [ "$SERVER_TYPE" = "foreign" ] && peer_tun_ip="${local_ip%.1}.2"

    ip link del "$dev" 2>/dev/null || true

    if [ "$SERVER_TYPE" = "iran" ]; then
        iptables -t nat -D PREROUTING -p tcp --dport 22 -j DNAT --to-destination "$local_ip" 2>/dev/null || true
        iptables -t nat -D PREROUTING -j DNAT --to-destination "$peer_tun_ip" 2>/dev/null || true
        iptables-save > "$IPTABLES_RULES"
    fi

    sed -i "${choice}d" "$GRE_DIR/tunnels.list"

    echo -e "${GREEN}Tunnel $name removed${NC}"
    echo "Run option 3 to update persistence."
}

enable_persistence() {
    echo -e "\n${GREEN}Enabling persistence on reboot${NC}"

    RESTORE_SCRIPT="/etc/gre-restore.sh"

    cat > "$RESTORE_SCRIPT" << EOF
#!/bin/bash
set -e

GRE_DIR="/etc/gre-tunnels"
SERVER_TYPE=\$(cat "\$GRE_DIR/server_type")
IPTABLES_RULES="/etc/iptables.rules"

modprobe ip_gre

while IFS='|' read -r name iran_ip foreign_ip tun_ip; do
  [ -z "\$name" ] && continue

  if [ "\$SERVER_TYPE" = "iran" ]; then
    local_ip="\$iran_ip"
    remote_ip="\$foreign_ip"
    tun_local="\$tun_ip"
  else
    local_ip="\$foreign_ip"
    remote_ip="\$iran_ip"
    tun_local="\$tun_ip"
  fi

  dev="gre-\${name}"

  ip tunnel add "\$dev" mode gre local "\$local_ip" remote "\$remote_ip" ttl 255
  ip link set "\$dev" up
  ip addr add "\$tun_local/30" dev "\$dev"
done < "\$GRE_DIR/tunnels.list"

if [ "\$SERVER_TYPE" = "iran" ]; then
  iptables-restore < "\$IPTABLES_RULES"
  echo 1 > /proc/sys/net/ipv4/ip_forward
  sysctl -p
fi
EOF

    chmod +x "$RESTORE_SCRIPT"

    SERVICE_FILE="/etc/systemd/system/gre-restore.service"

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Restore GRE tunnels and iptables on boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $RESTORE_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gre-restore.service

    echo -e "${GREEN}Persistence enabled. Tunnels and iptables will restore on reboot.${NC}"
}

show_menu() {
    clear
    echo -e "${GREEN}GRE Tunnel Manager ($SERVER_TYPE side)${NC}\n"
    show_list
    echo ""
    echo "  1) Add tunnel"
    echo "  2) Remove tunnel"
    echo "  3) Enable persistence on reboot"
    echo "  0) Exit"
    echo ""
    read -rp "Choice: " opt
}

[ "$EUID" -ne 0 ] && { echo -e "${RED}Run with sudo or as root${NC}"; exit 1; }

while true; do
    show_menu
    case $opt in
        1) add_tunnel ;;
        2) remove_tunnel ;;
        3) enable_persistence ;;
        0) echo -e "\nExiting..."; exit 0 ;;
        *) echo -e "${RED}Invalid option${NC}" ;;
    esac
    read -n1 -rsp $'\nPress Enter to continue...' dummy
done
