#!/bin/bash
# Run the client on the iMac from the MacBook over SSH. Builds and launches the
# signed RemoteMirrorClient.app through LaunchServices (so macOS attributes
# permissions to the app, not to SSH), waits for it, and prints its output.
# Extra arguments go to RemoteMirrorClient. Set RAW=1 to run the bare binary instead.
IMAC="${IMAC_USER:-andrea}@${IMAC_IP:-10.77.0.2}"
ARGS=$(printf ' %q' "$@")
if [ -n "${RAW:-}" ]; then
  exec ssh "$IMAC" "cd ~/iMacDisplay && .build/debug/RemoteMirrorClient$ARGS"
fi
exec ssh "$IMAC" "cd ~/iMacDisplay && scripts/build-client-app.sh >/dev/null && LOG=\$(mktemp /tmp/rm-client.XXXXXX) && \
  open -W -n --stdout \$LOG --stderr \$LOG .build/RemoteMirrorClient.app --args$ARGS; cat \$LOG; rm -f \$LOG"
