#!/bin/sh
# Motorola MH7601 Unit B routed 5GHz STA repeater fix
# EDIT UPSTREAM_PSK before running connect.
set -u
UPSTREAM_SSID="moto_net"
UPSTREAM_PSK="CHANGE_ME"
LAN_IP="192.168.1.1"
WPA_CONF="/tmp/q11-wpa.conf"
WPA_LOG="/tmp/q11-wpa.log"
WPA_PID="/tmp/q11-wpa.pid"
BACKUP_DIR="/root/q11-repeater-v2-backup"

log(){ echo "[q11-v2] $*"; }
stop_proc(){
  p="$1"; ids="$(pidof "$p" 2>/dev/null || true)"
  [ -z "$ids" ] && return
  log "Stopping $p: $ids"; kill $ids 2>/dev/null || true; sleep 1
  ids="$(pidof "$p" 2>/dev/null || true)"; [ -n "$ids" ] && kill -9 $ids 2>/dev/null || true
}
backup(){
  mkdir -p "$BACKUP_DIR"
  uci show wireless >"$BACKUP_DIR/wireless.txt" 2>/dev/null || true
  uci show network >"$BACKUP_DIR/network.txt" 2>/dev/null || true
  uci show firewall >"$BACKUP_DIR/firewall.txt" 2>/dev/null || true
  log "Backup saved in $BACKUP_DIR"
}
cleanup(){
  log "Stopping wireless managers and old wl1 users..."
  /etc/init.d/wetbridge stop 2>/dev/null || true
  /etc/init.d/wetbridge disable 2>/dev/null || true
  stop_proc acsd2; stop_proc wlssk; stop_proc openwrt_wifi_agent
  stop_proc hostapd; stop_proc wpa_supplicant
  rm -rf /var/run/wpa_supplicant 2>/dev/null || true
  mkdir -p /var/run/wpa_supplicant
  brctl delif br-lan wl1 2>/dev/null || true
  brctl delif br-lan wl1.1 2>/dev/null || true
  brctl delif br-lan wl1.5 2>/dev/null || true
  ip addr flush dev wl1 2>/dev/null || true
  ip link set wl1 down 2>/dev/null || true
  wl -i wl1 ap 0 2>/dev/null || true
  wl -i wl1 wet 0 2>/dev/null || true
  ip link set wl1 up 2>/dev/null || true
}
configure(){
  log "Writing routed-repeater UCI..."
  uci -q delete wireless.wl1_uplink
  uci set wireless.wl1_uplink='wifi-iface'
  uci set wireless.wl1_uplink.device='wl1'
  uci set wireless.wl1_uplink.mode='sta'
  uci set wireless.wl1_uplink.network='wwan'
  uci set wireless.wl1_uplink.ssid="$UPSTREAM_SSID"
  uci set wireless.wl1_uplink.encryption='psk2'
  uci set wireless.wl1_uplink.key="$UPSTREAM_PSK"
  uci set wireless.default_wl1.disabled='1'
  uci -q delete network.wwan
  uci set network.wwan='interface'
  uci set network.wwan.proto='dhcp'
  uci set network.wwan.ifname='wl1'
  uci set network.lan.proto='static'
  uci set network.lan.ipaddr="$LAN_IP"
  uci set network.lan.netmask='255.255.255.0'
  uci set network.lan.ifname='eth0 eth1 eth2 eth3 eth4'
  uci set network.wan.proto='none' 2>/dev/null || true
  uci -q delete firewall.wwan
  uci set firewall.wwan='zone'
  uci set firewall.wwan.name='wwan'
  uci set firewall.wwan.network='wwan'
  uci set firewall.wwan.input='REJECT'
  uci set firewall.wwan.output='ACCEPT'
  uci set firewall.wwan.forward='REJECT'
  uci set firewall.wwan.masq='1'
  uci set firewall.wwan.mtu_fix='1'
  uci -q delete firewall.lan_to_wwan
  uci set firewall.lan_to_wwan='forwarding'
  uci set firewall.lan_to_wwan.src='lan'
  uci set firewall.lan_to_wwan.dest='wwan'
  uci commit wireless; uci commit network; uci commit firewall
}
write_conf(){
  umask 077
  cat >"$WPA_CONF" <<EOF
ctrl_interface=/var/run/wpa_supplicant
update_config=0
country=PH
network={
    ssid="$UPSTREAM_SSID"
    psk="$UPSTREAM_PSK"
    scan_ssid=1
    proto=RSN
    key_mgmt=WPA-PSK
    pairwise=CCMP
    group=CCMP
    auth_alg=OPEN
    ieee80211w=0
}
EOF
  chmod 600 "$WPA_CONF"
}
start_wpa(){
  rm -f "$WPA_LOG" "$WPA_PID"
  wpa_supplicant -B -P "$WPA_PID" -i wl1 -D nl80211,wext -c "$WPA_CONF" -f "$WPA_LOG"
  sleep 2
  kill -0 "$(cat "$WPA_PID" 2>/dev/null)" 2>/dev/null
}
status(){
  echo "===== WPA ====="; wpa_cli -p /var/run/wpa_supplicant -i wl1 status 2>/dev/null || true
  echo "===== WL1 ====="; wl -i wl1 status 2>&1 || true; wl -i wl1 chanspec 2>&1 || true
  echo "===== IP ====="; ip addr show dev wl1 2>&1 || true
  echo "===== ROUTES ====="; ip route 2>&1 || true
  echo "===== WPA LOG ====="; tail -80 "$WPA_LOG" 2>/dev/null || true
}
wait_wpa(){
  i=0
  while [ "$i" -lt 45 ]; do
    s="$(wpa_cli -p /var/run/wpa_supplicant -i wl1 get_state 2>/dev/null || echo UNKNOWN)"
    echo "[$i/45] wpa_state=$s"
    [ "$s" = COMPLETED ] && return 0
    sleep 1; i=$((i+1))
  done
  return 1
}
dhcp(){
  log "Requesting DHCP on wl1..."
  killall udhcpc 2>/dev/null || true
  udhcpc -i wl1 -p /var/run/udhcpc-wwan.pid -s /lib/netifd/dhcp.script -n -q -t 5 -T 3 2>&1 || true
}
connect(){
  [ "$UPSTREAM_PSK" = CHANGE_ME ] && { log "Edit UPSTREAM_PSK first."; exit 2; }
  backup; cleanup; configure; write_conf
  log "Starting WPA2/RSN/CCMP STA on wl1..."
  start_wpa || { log "wpa_supplicant failed."; status; exit 1; }
  log "Waiting for authentication..."
  wait_wpa || { log "WPA authentication failed."; status; exit 1; }
  log "WPA authentication succeeded."
  dhcp
  status
  if ip addr show dev wl1 | grep -q 'inet 10\.10\.11\.'; then
    log "SUCCESS: wl1 has a 10.10.11.x address."
  else
    log "WARNING: Wi-Fi is authenticated, but DHCP did not give wl1 a 10.10.11.x address."
  fi
}
diagnose(){
  echo "===== PROCESSES ====="
  ps | grep -E 'wpa_supplicant|hostapd|acsd2|wlssk|openwrt_wifi_agent' | grep -v grep || true
  echo "===== WL1 ====="; wl -i wl1 status 2>&1 || true; wl -i wl1 chanspec 2>&1 || true
  echo "===== WPA ====="; wpa_cli -p /var/run/wpa_supplicant -i wl1 status 2>&1 || true
  echo "===== IP ====="; ip addr show dev wl1 2>&1 || true
}
reset(){
  killall wpa_supplicant 2>/dev/null || true; killall udhcpc 2>/dev/null || true
  uci -q delete wireless.wl1_uplink; uci delete wireless.default_wl1.disabled 2>/dev/null || true
  uci -q delete network.wwan; uci -q delete firewall.wwan; uci -q delete firewall.lan_to_wwan
  uci set network.lan.ifname='eth1 eth2 eth3 eth4'; uci set network.wan.proto='dhcp' 2>/dev/null || true
  uci commit wireless; uci commit network; uci commit firewall
  wifi reload 2>/dev/null || true
  /etc/init.d/network restart 2>/dev/null || true
  /etc/init.d/firewall restart 2>/dev/null || true
  log "Reset complete."
}
case "${1:-}" in
  connect) connect ;;
  diagnose) diagnose ;;
  status) status ;;
  reset) reset ;;
  *) echo "Usage: $0 {connect|diagnose|status|reset}" ;;
esac
