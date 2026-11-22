#!/bin/bash
# Run the client on the iMac from the MacBook over SSH. Builds and launches the
# signed RemoteMirrorClient.app through LaunchServices (so macOS attributes
# permissions to the app, not to SSH). Extra arguments go to RemoteMirrorClient.
#   default   wait for the app to exit, then print its output
#   BG=1      start it in the background; output goes to CLIENT_LOG on the iMac
#             (default /tmp/rm-client.log); returns immediately
#   RAW=1     run the bare binary instead of the app
IMAC="${IMAC_USER:-andrea}@${IMAC_IP:-10.77.0.2}"
ARGS=$(printf ' %q' "$@")
if [ -n "${RAW:-}" ]; then
  exec ssh "$IMAC" "cd ~/iMacDisplay && .build/debug/RemoteMirrorClient$ARGS"
fi
if [ -n "${BG:-}" ]; then
  LOG="${CLIENT_LOG:-/tmp/rm-client.log}"
  exec ssh "$IMAC" "cd ~/iMacDisplay && scripts/build-client-app.sh >/dev/null && : > $LOG && \
    open -n --stdout $LOG --stderr $LOG .build/RemoteMirrorClient.app --args$ARGS"
fi
exec ssh "$IMAC" "cd ~/iMacDisplay && scripts/build-client-app.sh >/dev/null && LOG=\$(mktemp /tmp/rm-client.XXXXXX) && \
  open -W -n --stdout \$LOG --stderr \$LOG .build/RemoteMirrorClient.app --args$ARGS; cat \$LOG; rm -f \$LOG"
