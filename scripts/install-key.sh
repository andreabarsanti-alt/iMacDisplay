#!/bin/bash
# Create the link's pre-shared key on the MacBook (if missing) and copy it to
# the iMac over the cable. The key lives in ~/.imacdisplay/psk (mode 600) on
# both Macs and never enters the repo.
set -euo pipefail
cd "$(dirname "$0")/.."
IMAC="${IMAC_USER:-andrea}@${IMAC_IP:-10.77.0.2}"
KEY="$HOME/.imacdisplay/psk"
[ -f "$KEY" ] || { swift build -q && .build/debug/RemoteMirrorHost --gen-key; }
chmod 600 "$KEY"
ssh "$IMAC" 'mkdir -p ~/.imacdisplay && chmod 700 ~/.imacdisplay && umask 077 && cat > ~/.imacdisplay/psk && chmod 600 ~/.imacdisplay/psk' < "$KEY"
L=$(shasum -a 256 "$KEY" | cut -c1-12); R=$(ssh "$IMAC" 'shasum -a 256 ~/.imacdisplay/psk' | cut -c1-12)
[ "$L" = "$R" ] && echo "Key installed on both Macs (fingerprint $L)" || { echo "Key mismatch"; exit 1; }
