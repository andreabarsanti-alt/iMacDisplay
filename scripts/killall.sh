#!/bin/bash
# Stop the host app on the MacBook and the client app on the iMac (over SSH).
IMAC="${IMAC_USER:-andrea}@${IMAC_IP:-10.77.0.2}"
pkill -f RemoteMirrorHost && echo "MacBook: host stopped" || echo "MacBook: host not running"
if ssh -o BatchMode=yes -o ConnectTimeout=3 "$IMAC" \
     'pkill -f RemoteMirrorClient && echo "iMac: client stopped" || echo "iMac: client not running"'; then :
else echo "iMac: unreachable (client will stop on missed heartbeat)"; fi
rm -f "$(dirname "$0")/../logs/"*.pid 2>/dev/null
exit 0
