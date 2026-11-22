#!/bin/bash
# Run the client on the iMac (it attaches to the logged-in GUI session of the same user),
# from the MacBook over SSH. Extra arguments go to RemoteMirrorClient.
IMAC="${IMAC_USER:-andrea}@${IMAC_IP:-10.77.0.2}"
ARGS=$(printf ' %q' "$@")
exec ssh "$IMAC" "cd ~/iMacDisplay && .build/debug/RemoteMirrorClient$ARGS"
