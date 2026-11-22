#!/bin/bash
# RemoteMirror uninstaller (same script for both Macs).
#
#   ./uninstall.sh                 remove everything and restore the original network settings
#   --keep-network                 leave the cable IP as it is
#   --keep-permissions             keep the macOS permission entries
#   --keep-key                     keep the pairing key
#   --keep-identity                keep the local signing identity
source "$(dirname "$0")/common.sh"
ROLE=$(cat "$HERE/ROLE" 2>/dev/null || echo unknown)
case "$ROLE" in
  macbook) ID=local.remotemirror.host;   SERVICES=(ScreenCapture Accessibility) ;;
  imac)    ID=local.remotemirror.client; SERVICES=(Accessibility) ;;
  *) die "unknown package role" ;;
esac
say "Uninstalling RemoteMirror ($ROLE)"

osascript -e "quit app id \"$ID\"" >/dev/null 2>&1 || true
sleep 1; pkill -f "$APPS/RemoteMirror.app/Contents/MacOS" 2>/dev/null || true

PL="$HOME/Library/LaunchAgents/local.remotemirror.client.plist"
[ -f "$PL" ] && { rm -f "$PL"; ok "login item removed"; }

if [ -d "$APPS/RemoteMirror.app" ]; then rm -rf "$APPS/RemoteMirror.app"; ok "app removed"; fi

if has_flag --keep-permissions "$@"; then warn "permissions kept"
else for s in "${SERVICES[@]}"; do tccutil reset "$s" "$ID" >/dev/null 2>&1 && ok "permission entry reset: $s"; done; fi

if has_flag --keep-key "$@"; then warn "pairing key kept"
else rm -f "$STATE/psk" "$HOME/Desktop/RemoteMirror-pairing.key"; ok "pairing key removed"; fi

if has_flag --keep-identity "$@"; then warn "signing identity kept"
else "$HERE/signing-cert.sh" remove >/dev/null 2>&1 && ok "signing identity removed"; fi

if has_flag --keep-network "$@"; then warn "network settings kept"
elif [ -d "$STATE/link-backup" ]; then
  say "Network: restoring the original settings (needs your password)"
  "$HERE/link.sh" revert
else warn "no network backup found; network left as it is"; fi

rm -f "$MANIFEST"
rmdir "$STATE" 2>/dev/null && ok "~/.imacdisplay removed" || true
say "Done."
