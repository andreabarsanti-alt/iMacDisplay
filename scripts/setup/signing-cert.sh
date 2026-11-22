#!/bin/bash
# Create (or remove) a local self-signed code-signing identity "RemoteMirror Dev"
# in a dedicated keychain (~/Library/Keychains/remotemirror.keychain-db), unlocked
# with a random password kept in ~/.imacdisplay/signing/kc-pass (mode 600).
# This lets builds over SSH sign without prompts, and macOS permissions granted
# to the signed app survive rebuilds. Your login keychain is not touched.
#
#   ./signing-cert.sh create   # create keychain + identity (idempotent)
#   ./signing-cert.sh unlock   # unlock the keychain (scripts call this before codesign)
#   ./signing-cert.sh status
#   ./signing-cert.sh remove   # delete keychain, identity and files
set -euo pipefail
NAME="RemoteMirror Dev"
DIR="$HOME/.imacdisplay/signing"
KC="$HOME/Library/Keychains/remotemirror.keychain-db"
PASSFILE="$DIR/kc-pass"

# set_search_list [extra]: user keychain search list without ours, plus [extra].
# Handles paths with spaces and an otherwise empty list.
set_search_list() {
  local list=()
  while IFS= read -r k; do
    k=$(echo "$k" | sed -e 's/^ *"//' -e 's/" *$//')
    [ -n "$k" ] && [ "$k" != "$KC" ] && list+=("$k")
  done < <(security list-keychains -d user)
  [ -n "${1:-}" ] && list+=("$1")
  security list-keychains -d user -s ${list[@]+"${list[@]}"}
}

unlock() { security unlock-keychain -p "$(cat "$PASSFILE")" "$KC"; security set-keychain-settings "$KC"; }  # no auto-lock

case "${1:-}" in
  create)
    mkdir -p "$DIR"; chmod 700 "$DIR"; cd "$DIR"
    if [ ! -f "$KC" ]; then
      umask 077; /usr/bin/openssl rand -hex 24 > "$PASSFILE"
      security create-keychain -p "$(cat "$PASSFILE")" "$KC"
      # Add to the user search list (keeping existing entries) so codesign finds it.
      set_search_list "$KC"
    fi
    unlock
    IDS=$(security find-identity -p codesigning "$KC")
    if grep -q "$NAME" <<<"$IDS"; then echo "Identity \"$NAME\" already exists."; exit 0; fi
    cat > cert.cnf <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout key.pem -out cert.pem -config cert.cnf 2>/dev/null
    P12PASS=$(/usr/bin/openssl rand -hex 16)
    /usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -name "$NAME" -out id.p12 -passout "pass:$P12PASS"
    security import id.p12 -k "$KC" -P "$P12PASS" -T /usr/bin/codesign >/dev/null
    # Let codesign use the key without a GUI prompt.
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$(cat "$PASSFILE")" "$KC" >/dev/null
    rm -f key.pem id.p12
    echo "Created \"$NAME\" in $KC"
    ;;
  unlock) unlock ;;
  status) security find-identity -p codesigning "$KC" 2>/dev/null | grep "$NAME" || echo "No identity \"$NAME\"." ;;
  remove)
    set_search_list
    security delete-keychain "$KC" 2>/dev/null || true
    rm -rf "$DIR"; echo "Removed \"$NAME\" and its keychain."
    ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
