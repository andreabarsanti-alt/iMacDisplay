#!/bin/bash
# Run on the MacBook. Lets the MacBook SSH into the iMac without a password.
#
#   ./ssh-key.sh install   # copy this MacBook's public key to the iMac (asks the iMac password once)
#   ./ssh-key.sh remove    # remove that key from the iMac and forget the iMac's host key
#   ./ssh-key.sh test      # check passwordless SSH works
#
# Override defaults with IMAC_USER=... IMAC_IP=... KEY=...
set -euo pipefail

IMAC_USER="${IMAC_USER:-andrea}"
IMAC_IP="${IMAC_IP:-10.77.0.2}"
KEY="${KEY:-$HOME/.ssh/id_ed25519.pub}"
TARGET="$IMAC_USER@$IMAC_IP"

[ -f "$KEY" ] || { echo "No public key at $KEY (create one with: ssh-keygen -t ed25519)"; exit 1; }

case "${1:-}" in
  install)
    ssh-copy-id -i "$KEY" "$TARGET"
    "$0" test
    ;;
  remove)
    pub=$(cut -d' ' -f1,2 "$KEY")
    # Remove every authorized_keys line containing this key; keep a backup on the iMac.
    ssh "$TARGET" "f=~/.ssh/authorized_keys; [ -f \$f ] || exit 0; cp \$f \$f.bak; grep -vF '$pub' \$f.bak > \$f || true; chmod 600 \$f; echo 'Key removed (backup: ~/.ssh/authorized_keys.bak)'"
    ssh-keygen -R "$IMAC_IP" >/dev/null 2>&1 && echo "Forgot host key for $IMAC_IP"
    ;;
  test)
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "$TARGET" 'echo "OK: $(whoami)@$(hostname) $(uname -m)"'; then
      echo "Passwordless SSH works."
    else
      echo "Passwordless SSH does NOT work."; exit 1
    fi
    ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
