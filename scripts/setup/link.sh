#!/bin/bash
# Configure (or revert) the direct Ethernet link between MacBook and iMac.
#
#   ./link.sh setup host     # on the MacBook: 10.77.0.1
#   ./link.sh setup client   # on the iMac:    10.77.0.2
#   ./link.sh revert         # restore the state saved by the first "setup"
#   ./link.sh status         # show current state, change nothing
#   ./link.sh detect         # show which adapter setup would use
#
# The adapter is detected (the wired one with the cable plugged in); override with
#   SERVICE="My Adapter" ./link.sh setup host
#
# The first "setup" saves the original state to ~/.imacdisplay/link-backup/.
# Later setups never overwrite it, so "revert" always goes back to the
# state before the very first setup. Needs an admin password (sudo).
set -euo pipefail

BACKUP="$HOME/.imacdisplay/link-backup"
MASK="255.255.255.0"

die() { echo "ERROR: $*" >&2; exit 1; }

services() { networksetup -listallnetworkservices | tail -n +2 | sed 's/^\*//'; }

# Wired candidates: (service<TAB>device) for Ethernet-like hardware ports, in service order.
wired_services() {
  networksetup -listnetworkserviceorder | awk '
    /^\([0-9*]+\)/ { sub(/^\([0-9*]+\) /, ""); svc=$0; next }
    /Hardware Port:/ {
      port=$0; sub(/.*Hardware Port: /, "", port); sub(/, Device:.*/, "", port)
      dev=$0;  sub(/.*Device: /, "", dev); sub(/\).*/, "", dev)
      if (dev != "" && port !~ /Wi-Fi|Bluetooth|Thunderbolt Bridge|iPhone|iPad|VPN|FireWire|Thunderbolt [0-9]/)
        print svc "\t" dev
    }'
}

link_active() { ifconfig "$1" 2>/dev/null | grep -q "status: active"; }

# Picks the network service for the cable: SERVICE=... if given, otherwise the wired
# adapter with the cable plugged in, the only wired adapter, or asks.
service_for_role() {
  if [ -n "${SERVICE:-}" ]; then echo "$SERVICE"; return; fi
  local all=() active=() line
  while IFS= read -r line; do [ -n "$line" ] && all+=("$line"); done < <(wired_services)
  for line in "${all[@]+"${all[@]}"}"; do link_active "${line#*$'\t'}" && active+=("$line"); done
  if [ ${#active[@]} -eq 1 ]; then echo "${active[0]%%$'\t'*}"; return; fi
  if [ ${#all[@]} -eq 1 ]; then echo "${all[0]%%$'\t'*}"; return; fi
  if [ ${#all[@]} -eq 0 ]; then
    echo "No wired network adapter found. Plug in the Ethernet adapter (with the cable to the" >&2
    echo "other Mac), then run the installer again. To skip this step: --skip-network" >&2
    exit 1
  fi
  local pool=("${all[@]}"); [ ${#active[@]} -gt 1 ] && pool=("${active[@]}")
  echo "Which adapter is connected to the other Mac?" >&2
  local i=1
  for line in "${pool[@]}"; do
    printf '  %d) %s (%s%s)\n' $i "${line%%$'\t'*}" "${line#*$'\t'}" "$(link_active "${line#*$'\t'}" && echo ", cable connected")" >&2
    i=$((i+1))
  done
  local n
  if ! { true </dev/tty; } 2>/dev/null; then echo "Run in a Terminal to choose, or set SERVICE=\"<name>\"." >&2; exit 1; fi
  read -r -p "Number: " n </dev/tty
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#pool[@]} ] || { echo "No adapter chosen." >&2; exit 1; }
  echo "${pool[$((n-1))]%%$'\t'*}"
}

check_service() {
  services | grep -qxF "$1" || {
    echo "Network service \"$1\" not found. Available services:" >&2
    services | sed 's/^/  /' >&2
    die "run again with SERVICE=\"<one of the names above>\""
  }
}

save_backup() {
  local svc="$1"
  if [ -d "$BACKUP" ]; then
    echo "Backup already exists in $BACKUP (kept, not overwritten)."
    return
  fi
  mkdir -p "$BACKUP"
  echo "$svc" > "$BACKUP/service"
  networksetup -getinfo "$svc" > "$BACKUP/ipv4"
  services > "$BACKUP/order"
  echo "Saved original state to $BACKUP"
}

set_manual() {
  local svc="$1" ip="$2"
  # Router left blank: try without router first, then with an empty one.
  sudo networksetup -setmanual "$svc" "$ip" "$MASK" 2>/dev/null \
    || sudo networksetup -setmanual "$svc" "$ip" "$MASK" ""
}

wifi_first() {
  local wifi; wifi=$(services | grep -xF "Wi-Fi" || true)
  if [ -z "$wifi" ]; then echo "No Wi-Fi service; order left unchanged."; return; fi
  local order=("Wi-Fi")
  while IFS= read -r s; do [ "$s" != "Wi-Fi" ] && order+=("$s"); done < <(services)
  sudo networksetup -ordernetworkservices "${order[@]}"
}

warn_internet_sharing() {
  local nat=/Library/Preferences/SystemConfiguration/com.apple.nat.plist
  if [ -f "$nat" ] && /usr/libexec/PlistBuddy -c "Print :NAT:Enabled" "$nat" 2>/dev/null | grep -q 1; then
    echo "WARNING: Internet Sharing (Condivisione Internet) is ON. Turn it off in"
    echo "         Impostazioni di Sistema > Generali > Condivisione."
  fi
}

status() {
  local svc; svc="${SERVICE:-$( [ -f "$BACKUP/service" ] && cat "$BACKUP/service" || true)}"
  echo "== Service order"; services | sed 's/^/  /'
  if [ -n "$svc" ]; then
    echo "== $svc"; networksetup -getinfo "$svc" | sed 's/^/  /'
    local dev; dev=$(networksetup -listallhardwareports | awk -v s="$svc" '$0=="Hardware Port: "s{getline; print $2}')
    [ -n "$dev" ] && ifconfig "$dev" | grep -E 'inet |media|status' | sed 's/^\t/  /'
  fi
  [ -d "$BACKUP" ] && echo "== Backup present: $BACKUP" || echo "== No backup saved yet"
  warn_internet_sharing
}

setup() {
  local role="${1:-}"; [ -n "$role" ] || die "usage: $0 setup host|client"
  local svc ip
  case "$role" in host) ip=10.77.0.1 ;; client) ip=10.77.0.2 ;; *) die "role must be host or client" ;; esac
  svc=$(service_for_role) || exit 1
  echo "Using network service: $svc"
  check_service "$svc"
  save_backup "$svc"
  echo "Setting $svc to $ip / $MASK, no router..."
  set_manual "$svc" "$ip"
  echo "Putting Wi-Fi first in the service order..."
  wifi_first
  warn_internet_sharing
  echo; status
}

revert() {
  [ -d "$BACKUP" ] || die "no backup in $BACKUP; nothing to revert to"
  local svc; svc=$(cat "$BACKUP/service")
  if head -1 "$BACKUP/ipv4" | grep -q '^DHCP'; then
    echo "Restoring $svc to DHCP..."
    sudo networksetup -setdhcp "$svc"
  else
    local ip mask router
    ip=$(awk -F': ' '/^IP address/{print $2}' "$BACKUP/ipv4")
    mask=$(awk -F': ' '/^Subnet mask/{print $2}' "$BACKUP/ipv4")
    router=$(awk -F': ' '/^Router/{print $2}' "$BACKUP/ipv4")
    echo "Restoring $svc to manual $ip / $mask / router ${router:-none}..."
    if [ -n "$router" ] && [ "$router" != "none" ] && [ "$router" != "(null)" ]; then
      sudo networksetup -setmanual "$svc" "$ip" "$mask" "$router"
    else
      sudo networksetup -setmanual "$svc" "$ip" "$mask" 2>/dev/null \
        || sudo networksetup -setmanual "$svc" "$ip" "$mask" ""
    fi
  fi
  # Restore order for services that still exist; append any new ones.
  local order=() s
  while IFS= read -r s; do services | grep -qxF "$s" && order+=("$s"); done < "$BACKUP/order"
  while IFS= read -r s; do printf '%s\n' "${order[@]}" | grep -qxF "$s" || order+=("$s"); done < <(services)
  echo "Restoring service order..."
  sudo networksetup -ordernetworkservices "${order[@]}"
  rm -rf "$BACKUP"
  echo "Reverted. Backup removed."
  echo; status
}

case "${1:-}" in
  setup)  setup "${2:-}" ;;
  revert) revert ;;
  status) status ;;
  detect) echo "wired adapters:"; wired_services | while IFS=$'\t' read -r svc dev; do
            printf '  %s (%s)%s\n' "$svc" "$dev" "$(link_active "$dev" && echo "  <- cable connected")"; done
          echo "setup would use: $(service_for_role)" ;;
  *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
