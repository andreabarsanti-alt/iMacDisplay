#!/bin/bash
# Put this MacBook's pairing key on the Desktop as RemoteMirror-pairing.key, to set up
# a second MacBook for the same iMac (copy the file next to its install.sh) or to
# re-pair an iMac. Treat the file like a password; the installers delete it after import.
source "$(dirname "$0")/common.sh"
[ -f "$STATE/psk" ] || die "no pairing key on this Mac (install RemoteMirror first)"
OUT="$HOME/Desktop/RemoteMirror-pairing.key"
cp "$STATE/psk" "$OUT"; chmod 600 "$OUT"
ok "pairing file: $OUT (fingerprint $(key_fingerprint))"
warn "AirDrop/USB it to the other Mac, next to its install.sh. Treat it like a password."
