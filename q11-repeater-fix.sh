#!/bin/sh
#
# Q11 5GHz STA / Routed Repeater Fix
# For Motorola MH7601/Q11 OpenWrt Minim/MotoSync firmware.
#
# Usage:
#   chmod 700 /root/q11-repeater-fix.sh
#   /root/q11-repeater-fix.sh help
#   /root/q11-repeater-fix.sh main-lock
#   /root/q11-repeater-fix.sh repeater-connect
#   /root/q11-repeater-fix.sh status
#   /root/q11-repeater-fix.sh reset
#
# IMPORTANT:
# 1. Edit UPSTREAM_SSID and UPSTREAM_PSK before running repeater-connect.
# 2. This script implements the ROUTED repeater design:
#       Unit A 5GHz AP -> Unit B wl1 STA -> wwan DHCP/NAT -> Unit B LAN/2.4GHz
# 3. eth0 can optionally be moved into br-lan for a wired client.
# 4. It deliberately does NOT put wl1 into br-lan.
# 5. It does NOT use WET mode for the routed repeater.
#

PATH=/usr/sbin:/usr/bin:/sbin:/bin

# =========================
# USER SETTINGS
# =========================

UPSTREAM_SSID="moto_net"
UPSTREAM_PSK="GcP$03Mar#13%75Moto_Net"

# Unit A 5GHz radio:
MAIN_5G_CHANNEL="36"
MAIN_5G_HTMODE="VHT80"

# Set to 1 if Unit B's eth0/WAN port should become a LAN port.
ETH0_TO_LAN="1"

# WPA2-Personal / AES.
WPA_PROTO="RSN"
WPA_KEY_MGMT="WPA-PSK"
WPA_PAIRWISE="CCMP"
WPA_GROUP="CCMP"

# wpa_supplicant driver to try first.
# If wext fails, the script automatically retries nl80211,wext.
WPA_DRIVER_FIRST="wext"

WPA_CONF="/tmp/q11_wl1_sta.conf"
WPA_LOG="/tmp/q11_wl1_sta.log"
WPA_PIDFILE="/var/run/q11_wl1_sta.pid"
BACKUP_DIR="/root/q11-repeater-backup"

log() {
    echo "[q11-fix] $*"
    logger -t q11-fix "$*" 2>/dev/null
}

die() {
    log "ERROR: $*"
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

check_commands() {
    for c in uci ip brctl wl wpa_supplicant wpa_cli pgrep awk grep cut sed sleep; do
        need_cmd "$c"
    done
}

backup_uci() {
    mkdir -p "$BACKUP_DIR" || return 0
    TS="$(date +%Y%m%d-%H%M%S 2>/dev/null)"
    [ -z "$TS" ] && TS="manual"

    uci export wireless > "$BACKUP_DIR/wireless-$TS.uci" 2>/dev/null
    uci export network  > "$BACKUP_DIR/network-$TS.uci" 2>/dev/null
    uci export firewall > "$BACKUP_DIR/firewall-$TS.uci" 2>/dev/null

    log "UCI backup saved under $BACKUP_DIR"
}

show_pid_cmd() {
    P="$1"
    [ -r "/proc/$P/cmdline" ] || return 0
    tr '\000' ' ' < "/proc/$P/cmdline" 2>/dev/null
}

kill_matching_processes() {
    NAME="$1"
    MATCH="$2"

    for P in $(pgrep "$NAME" 2>/dev/null); do
        CMD="$(show_pid_cmd "$P")"
        case "$CMD" in
            *"$MATCH"*)
                log "Stopping $NAME pid=$P: $CMD"
                kill "$P" 2>/dev/null
                ;;
        esac
    done
}

kill_all_named() {
    NAME="$1"
    for P in $(pgrep "$NAME" 2>/dev/null); do
        log "Stopping $NAME pid=$P"
        kill "$P" 2>/dev/null
    done
}

get_wl1_hostapd_pids() {
    for P in $(pgrep hostapd 2>/dev/null); do
        CMD="$(show_pid_cmd "$P")"
        echo "$CMD" | grep -q "wl1" && echo "$P"
    done
}

stop_radio_managers() {
    log "Stopping processes that can fight for wl1..."

    # These are Broadcom/OEM radio managers seen on this firmware.
    kill_all_named acsd2
    kill_all_named wlssk
    kill_all_named openwrt_wifi_agent

    # Only stop hostapd instances whose command line references wl1.
    for P in $(get_wl1_hostapd_pids); do
        log "Stopping wl1 hostapd pid=$P"
        kill "$P" 2>/dev/null
    done

    # Only stop a wpa_supplicant that is using wl1.
    kill_matching_processes wpa_supplicant "wl1"

    sleep 2
}

stop_our_wpa() {
    if [ -f "$WPA_PIDFILE" ]; then
        P="$(cat "$WPA_PIDFILE" 2>/dev/null)"
        [ -n "$P" ] && kill "$P" 2>/dev/null
        rm -f "$WPA_PIDFILE"
    fi

    wpa_cli -i wl1 terminate >/dev/null 2>&1
    kill_matching_processes wpa_supplicant "wl1"
}

restore_wl1_ap_state() {
    log "Restoring wl1 to AP mode..."
    stop_our_wpa

    ip link set wl1 down 2>/dev/null
    wl -i wl1 wet 0 2>/dev/null
    wl -i wl1 ap 1 2>/dev/null
    ip link set wl1 up 2>/dev/null

    # Do not blindly wifi reload here; it may restart the radio managers
    # while a manual STA test is in progress.
}

write_wpa_config() {
    [ "$UPSTREAM_SSID" != "CHANGE_ME" ] || die "Edit UPSTREAM_SSID first."
    [ "$UPSTREAM_PSK" != "CHANGE_ME" ] || die "Edit UPSTREAM_PSK first."

    cat > "$WPA_CONF" <<EOF
ctrl_interface=/var/run/wpa_supplicant
update_config=0

network={
    ssid="$UPSTREAM_SSID"
    psk="$UPSTREAM_PSK"
    key_mgmt=$WPA_KEY_MGMT
    proto=$WPA_PROTO
    pairwise=$WPA_PAIRWISE
    group=$WPA_GROUP
    scan_ssid=1
}
EOF

    chmod 600 "$WPA_CONF"
}

configure_unit_a_channel() {
    check_commands
    backup_uci

    log "Configuring Unit A 5GHz radio for a stable non-DFS test channel."

    [ -n "$(uci -q get wireless.wl1.type 2>/dev/null)" ] ||
        die "wireless.wl1 was not found. Run: uci show wireless"

    uci set "wireless.wl1.channel=$MAIN_5G_CHANNEL"
    uci set "wireless.wl1.htmode=$MAIN_5G_HTMODE"

    uci commit wireless || die "Could not commit wireless configuration."

    log "Unit A 5GHz: channel=$MAIN_5G_CHANNEL htmode=$MAIN_5G_HTMODE"
    log "Reloading Wi-Fi once..."
    wifi reload >/dev/null 2>&1

    sleep 8

    log "Unit A radio status:"
    wl -i wl1 status 2>/dev/null
    log "Unit A channel:"
    wl -i wl1 channel 2>/dev/null
}

configure_repeater_uci() {
    backup_uci

    log "Writing routed-repeater UCI configuration."

    # Keep the normal 2.4GHz AP/LAN. Add a separate 5GHz STA interface.
    uci -q delete wireless.wl1_uplink
    uci set wireless.wl1_uplink='wifi-iface'
    uci set wireless.wl1_uplink.device='wl1'
    uci set wireless.wl1_uplink.mode='sta'
    uci set "wireless.wl1_uplink.ssid=$UPSTREAM_SSID"
    uci set wireless.wl1_uplink.encryption='psk2'
    uci set "wireless.wl1_uplink.key=$UPSTREAM_PSK"
    uci set wireless.wl1_uplink.network='wwan'

    # The same 5GHz radio is dedicated to the upstream STA while repeater mode is active.
    # Disable the normal 5GHz AP interface so hostapd cannot fight the STA.
    uci set wireless.default_wl1.disabled='1'

    uci -q delete network.wwan
    uci set network.wwan='interface'
    uci set network.wwan.proto='dhcp'
    uci set network.wwan.ifname='wl1'

    # Unit B LAN/2.4GHz clients stay behind Unit B's DHCP/NAT.
    # Optional: make eth0 a LAN port instead of WAN.
    if [ "$ETH0_TO_LAN" = "1" ]; then
        uci set network.lan.ifname='eth0 eth1 eth2 eth3 eth4'
        uci set network.wan.proto='none'
        uci set network.wan.ifname='eth0'
    fi

    # Make sure the wwan zone exists.
    WZONE=""
    I=0
    while uci -q get "firewall.@zone[$I]" >/dev/null 2>&1; do
        ZNAME="$(uci -q get "firewall.@zone[$I].name")"
        [ "$ZNAME" = "wwan" ] && WZONE="$I"
        I=$((I + 1))
    done

    if [ -z "$WZONE" ]; then
        WZONE="$(uci add firewall zone)"
        uci set "firewall.$WZONE.name=wwan"
        uci set "firewall.$WZONE.network=wwan"
        uci set "firewall.$WZONE.input=REJECT"
        uci set "firewall.$WZONE.output=ACCEPT"
        uci set "firewall.$WZONE.forward=REJECT"
        uci set "firewall.$WZONE.masq=1"
        uci set "firewall.$WZONE.mtu_fix=1"
    else
        uci set "firewall.$WZONE.network=wwan"
        uci set "firewall.$WZONE.masq=1"
        uci set "firewall.$WZONE.mtu_fix=1"
    fi

    # Add LAN -> wwan forwarding if absent.
    FOUND=0
    I=0
    while uci -q get "firewall.@forwarding[$I]" >/dev/null 2>&1; do
        SRC="$(uci -q get "firewall.@forwarding[$I].src")"
        DST="$(uci -q get "firewall.@forwarding[$I].dest")"
        if [ "$SRC" = "lan" ] && [ "$DST" = "wwan" ]; then
            FOUND=1
            break
        fi
        I=$((I + 1))
    done

    if [ "$FOUND" = "0" ]; then
        FWD="$(uci add firewall forwarding)"
        uci set "firewall.$FWD.src=lan"
        uci set "firewall.$FWD.dest=wwan"
    fi

    uci commit wireless || die "Wireless UCI commit failed."
    uci commit network  || die "Network UCI commit failed."
    uci commit firewall || die "Firewall UCI commit failed."

    log "Routed repeater UCI configuration saved."
}

start_manual_sta() {
    write_wpa_config

    stop_our_wpa

    log "Putting wl1 into STA mode. WET is OFF for routed repeater."
    ip link set wl1 down 2>/dev/null
    wl -i wl1 ap 0 2>/dev/null
    wl -i wl1 wet 0 2>/dev/null
    ip link set wl1 up 2>/dev/null

    log "Starting wpa_supplicant using driver=$WPA_DRIVER_FIRST"

    : > "$WPA_LOG"

    wpa_supplicant \
        -D "$WPA_DRIVER_FIRST" \
        -i wl1 \
        -c "$WPA_CONF" \
        -B \
        -P "$WPA_PIDFILE" \
        -f "$WPA_LOG" \
        -dd >/dev/null 2>&1

    sleep 3

    STATE="$(wpa_cli -i wl1 status 2>/dev/null | awk -F= '/^wpa_state=/{print $2}')"

    if [ "$STATE" = "UNKNOWN" ] || [ -z "$STATE" ]; then
        log "wext did not initialize wl1 correctly; retrying with nl80211,wext."
        stop_our_wpa

        wpa_supplicant \
            -D nl80211,wext \
            -i wl1 \
            -c "$WPA_CONF" \
            -B \
            -P "$WPA_PIDFILE" \
            -f "$WPA_LOG" \
            -dd >/dev/null 2>&1

        sleep 3
    fi
}

wait_for_completed() {
    MAX="${1:-30}"
    I=0

    while [ "$I" -lt "$MAX" ]; do
        STATE="$(wpa_cli -i wl1 status 2>/dev/null | awk -F= '/^wpa_state=/{print $2}')"
        echo "[$I/$MAX] wpa_state=${STATE:-UNKNOWN}"

        case "$STATE" in
            COMPLETED)
                return 0
                ;;
            4WAY_HANDSHAKE)
                log "Reached 4WAY_HANDSHAKE: association works; WPA key negotiation is failing."
                ;;
            ASSOCIATED)
                log "Associated but not COMPLETED yet."
                ;;
            DISCONNECTED|INACTIVE|SCANNING|ASSOCIATING)
                ;;
        esac

        sleep 2
        I=$((I + 1))
    done

    return 1
}

configure_wwan_runtime() {
    log "Configuring wl1 as DHCP client on wwan."

    ip link set wl1 up 2>/dev/null

    # Make sure the logical interface uses wl1.
    uci set network.wwan.proto='dhcp'
    uci set network.wwan.ifname='wl1'
    uci commit network

    ifdown wwan >/dev/null 2>&1
    sleep 1
    ifup wwan >/dev/null 2>&1

    sleep 4
}

show_status() {
    echo
    echo "===== Q11 RADIO ====="
    wl -i wl1 status 2>&1
    echo
    echo "===== Q11 CHANNEL ====="
    wl -i wl1 channel 2>&1
    echo
    echo "===== WPA ====="
    wpa_cli -i wl1 status 2>&1
    echo
    echo "===== WL1 LINK ====="
    if command -v iw >/dev/null 2>&1; then
        iw dev wl1 link 2>&1
    else
        echo "iw not installed; using wl status above."
    fi
    echo
    echo "===== WL1 IP ====="
    ip addr show wl1 2>&1
    echo
    echo "===== ROUTES ====="
    ip route 2>&1
    echo
    echo "===== BR-LAN ====="
    brctl show br-lan 2>&1
    echo
    echo "===== WWAN UCI ====="
    uci show network.wwan 2>&1
    echo
    echo "===== WIRELESS UCI ====="
    uci show wireless.wl1 2>&1
    uci show wireless.wl1_uplink 2>&1
}

run_verification_loop() {
    echo
    echo "===== 30-SECOND VERIFICATION ====="

    I=1
    while [ "$I" -le 15 ]; do
        echo
        echo "----- TEST $I/15 -----"
        DATE="$(date 2>/dev/null)"
        echo "time: $DATE"

        STATE="$(wpa_cli -i wl1 status 2>/dev/null | awk -F= '/^wpa_state=/{print $2}')"
        SSID="$(wpa_cli -i wl1 status 2>/dev/null | awk -F= '/^ssid=/{print $2}')"
        BSSID="$(wpa_cli -i wl1 status 2>/dev/null | awk -F= '/^bssid=/{print $2}')"

        echo "wpa_state=${STATE:-UNKNOWN}"
        echo "ssid=${SSID:-UNKNOWN}"
        echo "bssid=${BSSID:-UNKNOWN}"

        wl -i wl1 status 2>&1 | sed -n '1,8p'
        echo "--- IP ---"
        ip addr show wl1 2>&1 | sed -n '1,8p'
        echo "--- route ---"
        ip route 2>&1 | sed -n '1,8p'

        I=$((I + 1))
        sleep 2
    done

    echo
    echo "===== WPA LOG TAIL ====="
    tail -40 "$WPA_LOG" 2>/dev/null
}

repeater_connect() {
    check_commands

    [ "$UPSTREAM_SSID" != "CHANGE_ME" ] ||
        die "Edit UPSTREAM_SSID in this script."
    [ "$UPSTREAM_PSK" != "CHANGE_ME" ] ||
        die "Edit UPSTREAM_PSK in this script."

    backup_uci

    log "Starting clean Unit B routed-repeater connection."

    # Prevent the WET service from taking wl1.
    if [ -x /etc/init.d/wetbridge ]; then
        /etc/init.d/wetbridge stop >/dev/null 2>&1
        /etc/init.d/wetbridge disable >/dev/null 2>&1
    fi

    # Kill radio managers BEFORE changing wl1.
    stop_radio_managers

    # Remove wl1 from br-lan if the old WET/AP state left it there.
    brctl delif br-lan wl1 >/dev/null 2>&1

    configure_repeater_uci
    start_manual_sta

    log "Waiting for WPA completion..."
    if ! wait_for_completed 30; then
        log "STA did not reach COMPLETED."
        log "Current status:"
        wpa_cli -i wl1 status 2>&1
        log "wl status:"
        wl -i wl1 status 2>&1
        log "Recent WPA log:"
        tail -60 "$WPA_LOG" 2>/dev/null
        exit 2
    fi

    log "WPA COMPLETED. Now requesting DHCP on wwan."
    configure_wwan_runtime

    log "Final status:"
    show_status

    run_verification_loop

    log "Done."
    log "IMPORTANT: Do not run 'wifi reload' during this manual STA test."
}

reset_to_normal() {
    check_commands
    backup_uci

    log "Resetting Unit B wl1/WET/STA state."

    if [ -x /etc/init.d/wetbridge ]; then
        /etc/init.d/wetbridge stop >/dev/null 2>&1
        /etc/init.d/wetbridge disable >/dev/null 2>&1
    fi

    stop_our_wpa

    # Stop wl1 hostapd only.
    for P in $(get_wl1_hostapd_pids); do
        kill "$P" 2>/dev/null
    done

    # Stop Broadcom managers so they don't race the cleanup.
    kill_all_named acsd2
    kill_all_named wlssk
    kill_all_named openwrt_wifi_agent

    # Remove WET bridge if it exists.
    ip link set br-pass down 2>/dev/null
    brctl delif br-pass wl1 2>/dev/null
    brctl delif br-pass eth0 2>/dev/null
    brctl delbr br-pass 2>/dev/null

    # Restore wl1 to AP mode.
    ip link set wl1 down 2>/dev/null
    wl -i wl1 wet 0 2>/dev/null
    wl -i wl1 ap 1 2>/dev/null
    ip link set wl1 up 2>/dev/null

    # Remove manual STA config and restore the normal 5GHz AP interface.
    uci -q delete wireless.wl1_uplink
    uci -q delete wireless.default_wl1.disabled
    uci -q delete network.wwan

    # Restore normal LAN/WAN split.
    uci set network.lan.ifname='eth1 eth2 eth3 eth4'
    uci set network.wan.proto='dhcp'
    uci set network.wan.ifname='eth0'

    # Remove wwan firewall zone and its LAN->wwan forwarding.
    I=0
    while uci -q get "firewall.@zone[$I]" >/dev/null 2>&1; do
        ZNAME="$(uci -q get "firewall.@zone[$I].name")"
        if [ "$ZNAME" = "wwan" ]; then
            uci delete "firewall.@zone[$I]"
            break
        fi
        I=$((I + 1))
    done

    I=0
    while uci -q get "firewall.@forwarding[$I]" >/dev/null 2>&1; do
        SRC="$(uci -q get "firewall.@forwarding[$I].src")"
        DST="$(uci -q get "firewall.@forwarding[$I].dest")"
        if [ "$SRC" = "lan" ] && [ "$DST" = "wwan" ]; then
            uci delete "firewall.@forwarding[$I]"
            break
        fi
        I=$((I + 1))
    done

    uci commit wireless
    uci commit network
    uci commit firewall

    rm -f "$WPA_CONF" "$WPA_LOG" "$WPA_PIDFILE"

    log "Cleanup complete."
    log "Starting normal Wi-Fi configuration once."
    wifi reload >/dev/null 2>&1
    sleep 8

    show_status
}

scan_only() {
    check_commands

    log "Preparing wl1 for a manual scan."
    stop_our_wpa

    ip link set wl1 down 2>/dev/null
    wl -i wl1 ap 0 2>/dev/null
    wl -i wl1 wet 0 2>/dev/null
    ip link set wl1 up 2>/dev/null

    wl -i wl1 scan >/dev/null 2>&1
    sleep 5

    echo "===== SCAN RESULTS ====="
    wl -i wl1 scanresults 2>&1
}

usage() {
    cat <<EOF
Q11 5GHz STA / Routed Repeater Fix

Edit these variables at the top of this script first:
  UPSTREAM_SSID="..."
  UPSTREAM_PSK="..."

Commands:

  main-lock
      On Unit A: lock 5GHz to channel 36 / VHT80 and reload Wi-Fi.

  repeater-connect
      On Unit B:
        - stop WET service
        - stop wl1 radio managers
        - stop wl1 hostapd
        - remove wl1 from br-lan
        - configure WPA2/RSN/CCMP
        - put wl1 in STA mode
        - connect with wpa_supplicant
        - wait for COMPLETED
        - request DHCP on wwan
        - configure routed LAN->wwan NAT
        - print a 30-second verification loop

  scan
      Scan for 5GHz APs using wl1.

  status
      Show wl1, WPA, IP, routes, bridge and UCI state.

  reset
      Stop STA/WET, remove wwan configuration, restore wl1 AP mode,
      restore eth0 as WAN, remove wwan firewall rules, and reload Wi-Fi.

IMPORTANT:
  This script intentionally does NOT add wl1 to br-lan.
  The routed repeater is:
      Unit A 5G AP
          |
       5G STA (wl1)
          |
        wwan
       DHCP/NAT
          |
       br-lan
       /    \
    2.4GHz  LAN
EOF
}

case "$1" in
    main-lock)
        configure_unit_a_channel
        ;;
    repeater-connect)
        repeater_connect
        ;;
    scan)
        scan_only
        ;;
    status)
        check_commands
        show_status
        ;;
    reset)
        reset_to_normal
        ;;
    help|"")
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
