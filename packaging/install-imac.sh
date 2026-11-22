#!/bin/bash
# RemoteMirror installer for the iMac (shows the MacBook, sends keyboard/mouse back).
#
#   ./install.sh                          full install (looks for RemoteMirror-pairing.key
#                                         in this folder, ~/Downloads and ~/Desktop)
#   ./install.sh --pairing-file PATH      pairing file from the MacBook installer
#   ./install.sh --skip-network           don't touch the network settings
#   ./install.sh --login-item             start RemoteMirror (waiting) at login
#
# Steps: cable IP 10.77.0.2 (original settings backed up), local signing identity,
# RemoteMirror.app in ~/Applications, pairing key import, permissions. Undo: ./uninstall.sh
source "$(dirname "$0")/common.sh"

[ "$(uname -m)" = x86_64 ] || warn "this package is built for Intel iMacs (found $(uname -m)); it will run under Rosetta"
say "Installing RemoteMirror for the iMac"

if has_flag --skip-network "$@"; then warn "network: skipped (--skip-network)"
else
  say "Network: cable link 10.77.0.2 (needs your password)"
  SERVICE="${SERVICE:-Ethernet}" "$HERE/link.sh" setup client && record network
fi

say "Pairing key"
PAIR=$(flag_value --pairing-file "$@")
if [ -z "$PAIR" ]; then
  for f in "$HERE/RemoteMirror-pairing.key" "$HOME/Downloads/RemoteMirror-pairing.key" "$HOME/Desktop/RemoteMirror-pairing.key"; do
    [ -f "$f" ] && { PAIR=$f; break; }
  done
fi
if [ -n "$PAIR" ]; then
  K=$(tr -d '[:space:]' < "$PAIR")
  [[ "$K" =~ ^[0-9a-f]{64}$ ]] || die "$PAIR is not a RemoteMirror pairing file"
  store_key "$K"; record key
  has_flag --keep-pairing-file "$@" || rm -f "$PAIR"
  ok "key imported (fingerprint $(key_fingerprint)); pairing file deleted"
elif [ -f "$STATE/psk" ]; then ok "existing key kept (fingerprint $(key_fingerprint))"
else die "no pairing file found; run the MacBook installer first and copy RemoteMirror-pairing.key here"; fi

say "App"
install_app "$HERE/RemoteMirror.app" RemoteMirror local.remotemirror.client
record app; record identity

if has_flag --login-item "$@"; then
  PL="$HOME/Library/LaunchAgents/local.remotemirror.client.plist"
  mkdir -p "$(dirname "$PL")"
  cat > "$PL" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.remotemirror.client</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>$APPS/RemoteMirror.app</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST
  record loginitem; ok "starts at login (waiting for the MacBook)"
fi

say "Permissions"
if has_flag --skip-permissions "$@"; then STATUS=$(run_app "$APPS/RemoteMirror.app" --check-permissions); else
STATUS=$(run_app "$APPS/RemoteMirror.app" --request-permissions); fi
echo "$STATUS" | grep -q '"accessibility","status":"granted"' && ok "Accessibility granted" || {
  warn "Accessibility: turn on RemoteMirror in System Settings > Privacy & Security > Accessibility (for Cmd-Tab etc.)"
  has_flag --skip-permissions "$@" || open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"; }
warn "Local Network: if asked, click Allow (System Settings > Privacy & Security > Local Network > RemoteMirror)"

say "Done. Starting RemoteMirror: it waits for the MacBook to start sharing."
has_flag --no-launch "$@" || open "$APPS/RemoteMirror.app" || true
