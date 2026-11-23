# Shared helpers for the RemoteMirror installers (sourced, not run).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$HOME/.imacdisplay"
APPS="$HOME/Applications"
MANIFEST="$STATE/install.manifest"
say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
record() { mkdir -p "$STATE"; echo "$1" >> "$MANIFEST"; }
recorded() { [ -f "$MANIFEST" ] && grep -qx "$1" "$MANIFEST"; }
has_flag() { local f=$1; shift; for a in "$@"; do [ "$a" = "$f" ] && return 0; done; return 1; }
flag_value() { local f=$1; shift; while [ $# -gt 0 ]; do [ "$1" = "$f" ] && { echo "${2:-}"; return; }; shift; done; }

# install_app <source .app> <name> <bundle id>: copy to ~/Applications and sign locally.
install_app() {
  local src=$1 name=$2 id=$3 dst="$APPS/$2.app"
  mkdir -p "$APPS"
  osascript -e "quit app id \"$id\"" >/dev/null 2>&1 || true
  pkill -f "$dst/Contents/MacOS" 2>/dev/null || true
  rm -rf "$dst"; cp -R "$src" "$dst"
  # Downloaded zips carry the quarantine flag; Gatekeeper would refuse the locally signed app.
  xattr -dr com.apple.quarantine "$dst" 2>/dev/null || true
  if [ -n "${RM_TEST_SKIP_SIGN:-}" ]; then ok "installed $dst (signing skipped: test mode)"; return; fi
  "$HERE/signing-cert.sh" create >/dev/null
  "$HERE/signing-cert.sh" unlock
  codesign -f -s "RemoteMirror Dev" --keychain "$HOME/Library/Keychains/remotemirror.keychain-db" \
    --identifier "$id" "$dst" 2>&1 | grep -v "replacing existing signature" || true
  codesign -v "$dst" || die "signature check failed for $dst"
  # Must be signed by the local identity (stable across reinstalls), not ad-hoc.
  # (capture first: `codesign | grep -q` fails under pipefail when grep exits early)
  local info; info=$(codesign -dvv "$dst" 2>&1)
  grep -q "^Authority=RemoteMirror Dev" <<<"$info" || die "could not sign $dst with the local identity"
  # Re-register so Finder/Dock show the current icon rather than a cached one.
  touch "$dst"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dst" 2>/dev/null || true

  ok "installed $dst (signed: $(codesign -d -r- "$dst" 2>&1 | tail -1 | sed 's/.*certificate leaf = //'))"
}

# run_app <app> <args...>: run the installed app through LaunchServices (so macOS
# attributes permission requests to it) and print its output.
run_app() {
  local app=$1; shift
  local log; log=$(mktemp /tmp/rm-install.XXXXXX)
  open -W -n --stdout "$log" --stderr "$log" "$app" --args "$@"
  cat "$log"; rm -f "$log"
}

# Writes ~/.imacdisplay/psk from a 64-hex-character key.
store_key() {
  mkdir -p "$STATE"; chmod 700 "$STATE"
  (umask 077; printf '%s\n' "$1" > "$STATE/psk"); chmod 600 "$STATE/psk"
}
key_fingerprint() { shasum -a 256 "$STATE/psk" | cut -c1-12; }
