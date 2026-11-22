#!/bin/bash
# RemoteMirror installer for the MacBook (screen + keyboard/mouse shared to the iMac).
#
#   ./install.sh                      full install
#   ./install.sh --skip-network       don't touch the network settings
#   ./install.sh --push-to USER@10.77.0.2
#                                     also copy the pairing key to the iMac over SSH
#   ./install.sh --pairing-file PATH  use an existing pairing key (e.g. a second MacBook
#                                     for the same iMac; made with ./export-pairing.sh).
#                                     Found automatically next to this script, in
#                                     ~/Downloads or on the Desktop.
#
# Steps: cable IP 10.77.0.1 (original settings backed up), local signing identity,
# RemoteMirror.app in ~/Applications, pairing key, permissions. Undo: ./uninstall.sh
source "$(dirname "$0")/common.sh"

say "Installing RemoteMirror for the MacBook"

if has_flag --skip-network "$@"; then warn "network: skipped (--skip-network)"
else
  say "Network: cable link 10.77.0.1 (needs your password)"
  SERVICE="${SERVICE:-}" "$HERE/link.sh" setup host && record network
fi

say "App"
install_app "$HERE/RemoteMirror.app" RemoteMirror local.remotemirror.host
record app; record identity

say "Pairing key"
IMPORT=$(flag_value --pairing-file "$@")
if [ -z "$IMPORT" ] && [ ! -f "$STATE/psk" ]; then
  for f in "$HERE/RemoteMirror-pairing.key" "$HOME/Downloads/RemoteMirror-pairing.key" "$HOME/Desktop/RemoteMirror-pairing.key"; do
    [ -f "$f" ] && { IMPORT=$f; break; }
  done
fi
NEWKEY=0
if [ -n "$IMPORT" ]; then
  K=$(tr -d '[:space:]' < "$IMPORT")
  [[ "$K" =~ ^[0-9a-f]{64}$ ]] || die "$IMPORT is not a RemoteMirror pairing file"
  store_key "$K"; record key; rm -f "$IMPORT"
  ok "key imported (fingerprint $(key_fingerprint)): this MacBook pairs with the same iMac; pairing file deleted"
elif [ -f "$STATE/psk" ]; then ok "existing key kept (fingerprint $(key_fingerprint))"
else store_key "$(/usr/bin/openssl rand -hex 32)"; ok "new key (fingerprint $(key_fingerprint))"; record key; NEWKEY=1; fi
PAIR="$HOME/Desktop/RemoteMirror-pairing.key"
# Only a brand-new key has to go to the iMac; an imported or existing one is already there.
if [ $NEWKEY = 1 ] || has_flag --export-pairing "$@"; then cp "$STATE/psk" "$PAIR"; chmod 600 "$PAIR"; else PAIR=""; fi
TARGET=$(flag_value --push-to "$@")
if [ -n "$TARGET" ]; then
  if ssh -o BatchMode=yes -o ConnectTimeout=5 "$TARGET" 'mkdir -p ~/.imacdisplay && chmod 700 ~/.imacdisplay && umask 077 && cat > ~/.imacdisplay/psk && chmod 600 ~/.imacdisplay/psk' < "$STATE/psk"; then
    ok "key copied to $TARGET"; [ -n "$PAIR" ] && rm -f "$PAIR"
  else warn "could not reach $TARGET over SSH; use the pairing file instead"; fi
fi
[ -n "$PAIR" ] && [ -f "$PAIR" ] && { ok "pairing file: $PAIR"; warn "copy it to the iMac (AirDrop/USB) and run the iMac installer; it is deleted there after import. Treat it like a password."; }

say "Permissions"
if has_flag --skip-permissions "$@"; then STATUS=$(run_app "$APPS/RemoteMirror.app" --check-permissions); else
STATUS=$(run_app "$APPS/RemoteMirror.app" --request-permissions); fi
echo "$STATUS" | grep -q '"screen_recording","status":"granted"' && ok "Screen Recording granted" || {
  warn "Screen Recording: turn on RemoteMirror in System Settings > Privacy & Security > Screen & System Audio Recording"
  has_flag --skip-permissions "$@" || open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"; }
echo "$STATUS" | grep -q '"accessibility","status":"granted"' && ok "Accessibility granted" || {
  warn "Accessibility: turn on RemoteMirror in System Settings > Privacy & Security > Accessibility"
  has_flag --skip-permissions "$@" || open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"; }

say "Done. Open RemoteMirror from ~/Applications; it lives in the menu bar."
has_flag --no-launch "$@" || open "$APPS/RemoteMirror.app" || true
