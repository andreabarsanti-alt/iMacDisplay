#!/bin/bash
# Preflight checks, run from the MacBook. Prints PASS / WARN / FAIL per check
# and ends with the Gate 1 verdict. Changes no system settings, never uses sudo.
#
#   scripts/preflight.sh            # full run (30 s ping, 10 s throughput each way)
#   QUICK=1 scripts/preflight.sh    # short run (5 s ping, 3 s throughput)
#
# Overrides: IMAC_USER (andrea), IMAC_IP (10.77.0.2), HOST_IP (10.77.0.1),
#            IMAC_REPO (~/iMacDisplay on the iMac)
set -uo pipefail
cd "$(dirname "$0")/.."

IMAC_USER="${IMAC_USER:-andrea}"
IMAC_IP="${IMAC_IP:-10.77.0.2}"
HOST_IP="${HOST_IP:-10.77.0.1}"
IMAC_REPO="${IMAC_REPO:-iMacDisplay}"
TARGET="$IMAC_USER@$IMAC_IP"
PING_COUNT=30; TPUT_SECS=10
[ -n "${QUICK:-}" ] && { PING_COUNT=5; TPUT_SECS=3; }

# Gate 1 thresholds
MIN_MBPS=900; MAX_PING_MS=1.0

FAILS=0; WARNS=0
pass() { printf '\033[32mPASS\033[0m  %s\n' "$*"; }
warn() { printf '\033[33mWARN\033[0m  %s\n' "$*"; WARNS=$((WARNS+1)); }
fail() { printf '\033[31mFAIL\033[0m  %s\n' "$*"; FAILS=$((FAILS+1)); }
info() { printf '      %s\n' "$*"; }
remote() { ssh -o BatchMode=yes -o ConnectTimeout=5 "$TARGET" "export PATH=/usr/local/bin:/opt/homebrew/bin:\$PATH; $*"; }
# version_le A B  -> true if A <= B (dotted numeric)
version_le() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$1" ]; }
swift_ver() { sed -nE 's/.*Apple Swift version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' | head -1; }

if [ -f STOP ]; then echo "STOP file present: not running."; exit 2; fi

echo "== 3. SSH to iMac ($TARGET)"
if remote true 2>/dev/null; then pass "non-interactive SSH works"
else fail "SSH to $TARGET failed (run scripts/setup/ssh-key.sh install)"; echo; echo "Gate 1: FAIL (cannot reach iMac)"; exit 1; fi

echo "== 1. OS and architecture"
L_ARCH=$(uname -m); L_OS=$(sw_vers -productVersion)
R_ARCH=$(remote uname -m); R_OS=$(remote sw_vers -productVersion)
info "MacBook: $L_ARCH, macOS $L_OS   iMac: $R_ARCH, macOS $R_OS"
[ "$L_ARCH" = arm64 ] && pass "MacBook is arm64" || fail "MacBook is $L_ARCH, expected arm64"
[ "$R_ARCH" = x86_64 ] && pass "iMac is x86_64" || fail "iMac is $R_ARCH, expected x86_64"

echo "== 2. Toolchains vs package requirements"
L_SWIFT=$(swift --version 2>&1 | swift_ver); R_SWIFT=$(remote 'swift --version 2>&1' | swift_ver)
TOOLS=$(sed -nE '1s/.*swift-tools-version: *([0-9.]+).*/\1/p' Package.swift)
DEPLOY=$(sed -nE 's/.*\.macOS\(\.v([0-9]+)\).*/\1/p' Package.swift)
info "Swift: MacBook $L_SWIFT, iMac $R_SWIFT; package tools $TOOLS, deployment macOS $DEPLOY"
for side in "MacBook:$L_SWIFT" "iMac:$R_SWIFT"; do
  n=${side%%:*}; v=${side#*:}
  version_le "$TOOLS" "$v" && pass "$n Swift $v supports swift-tools-version $TOOLS" \
    || fail "$n Swift $v is older than swift-tools-version $TOOLS"
done
for side in "MacBook:$L_OS" "iMac:$R_OS"; do
  n=${side%%:*}; v=${side#*:}
  version_le "$DEPLOY" "$v" && pass "$n macOS $v >= deployment target $DEPLOY" \
    || fail "$n macOS $v is below deployment target $DEPLOY"
done
for side in local remote; do
  if [ $side = local ]; then x=$(xcodebuild -version 2>/dev/null | head -1); n=MacBook
  else x=$(remote 'xcodebuild -version 2>/dev/null | head -1'); n=iMac; fi
  [ -n "$x" ] && info "$n: $x" || info "$n: Command Line Tools only (no Xcode); fine for swift build"
done

echo "== 4. Git repo in sync"
L_HEAD=$(git rev-parse HEAD); R_HEAD=$(remote "git -C $IMAC_REPO rev-parse HEAD 2>/dev/null")
if [ -z "$R_HEAD" ]; then fail "no repo at ~/$IMAC_REPO on the iMac"
elif [ "$L_HEAD" = "$R_HEAD" ]; then pass "both at ${L_HEAD:0:7}"
else warn "MacBook at ${L_HEAD:0:7}, iMac at ${R_HEAD:0:7} (push with: git push imac HEAD)"; fi
[ -z "$(git status --porcelain)" ] || warn "uncommitted changes on the MacBook"

echo "== 8. Link interface"
L_IF=$(route -n get "$IMAC_IP" 2>/dev/null | awk '/interface:/{print $2}')
R_IF=$(remote "route -n get $HOST_IP 2>/dev/null | awk '/interface:/{print \$2}'")
for side in "MacBook:$L_IF:local" "iMac:$R_IF:remote"; do
  IFS=: read -r n ifc where <<<"$side"
  if [ -z "$ifc" ]; then fail "$n: no route over the link"; continue; fi
  if [ "$where" = local ]; then cfg=$(ifconfig "$ifc"); else cfg=$(remote "ifconfig $ifc"); fi
  media=$(echo "$cfg" | sed -nE 's/.*media: .*\((.*)\).*/\1/p')
  mask=$(echo "$cfg" | awk '/inet 10\.77\./{print $4}')
  if echo "$media" | grep -q 1000baseT && echo "$media" | grep -q full-duplex; then pass "$n $ifc: $media"
  else fail "$n $ifc: $media (expected 1000baseT full-duplex; try a Cat5e/Cat6 cable)"; fi
  [ "$mask" = 0xffffff00 ] && pass "$n subnet mask 255.255.255.0" || warn "$n subnet mask $mask (expected 255.255.255.0)"
done
nat=/Library/Preferences/SystemConfiguration/com.apple.nat.plist
for where in local remote; do
  n=$([ $where = local ] && echo MacBook || echo iMac)
  cmd="[ -f $nat ] && /usr/libexec/PlistBuddy -c 'Print :NAT:Enabled' $nat 2>/dev/null || echo 0"
  if [ $where = local ]; then v=$(eval "$cmd"); else v=$(remote "$cmd"); fi
  [ "$v" = 1 ] && fail "$n: Internet Sharing is ON" || pass "$n: Internet Sharing off"
done

echo "== 5. Network quality over the link"
PING=$(ping -c "$PING_COUNT" -i 1 "$IMAC_IP" 2>&1 | tail -2)
LOSS=$(echo "$PING" | sed -nE 's/.* ([0-9.]+)% packet loss.*/\1/p')
read -r PMIN PAVG PMAX PSTD < <(echo "$PING" | sed -nE 's|.*= ([0-9.]+)/([0-9.]+)/([0-9.]+)/([0-9.]+) ms|\1 \2 \3 \4|p')
info "ping x$PING_COUNT: loss ${LOSS:-?}%, min/avg/max/stddev ${PMIN:-?}/${PAVG:-?}/${PMAX:-?}/${PSTD:-?} ms"
[ "${LOSS:-100}" = "0.0" ] && pass "no packet loss" || fail "packet loss ${LOSS:-100}%"
if [ -n "${PAVG:-}" ] && awk "BEGIN{exit !($PAVG < $MAX_PING_MS)}"; then pass "avg ping ${PAVG} ms < ${MAX_PING_MS} ms"
else fail "avg ping ${PAVG:-?} ms (target < ${MAX_PING_MS} ms)"; fi

mbps_check() { # label mbps
  if awk "BEGIN{exit !($2 >= $MIN_MBPS)}"; then pass "$1: $2 Mbps"
  else fail "$1: $2 Mbps (target >= $MIN_MBPS)"; fi
}
if command -v iperf3 >/dev/null && remote 'command -v iperf3' >/dev/null; then
  remote "pkill -x iperf3; nohup iperf3 -s -B $IMAC_IP -p 5201 >/dev/null 2>&1 &"; sleep 1
  UP=$(iperf3 -c "$IMAC_IP" -p 5201 -t "$TPUT_SECS" -J 2>/dev/null | python3 -c 'import json,sys;print(round(json.load(sys.stdin)["end"]["sum_received"]["bits_per_second"]/1e6))' 2>/dev/null)
  DOWN=$(iperf3 -c "$IMAC_IP" -p 5201 -t "$TPUT_SECS" -R -J 2>/dev/null | python3 -c 'import json,sys;print(round(json.load(sys.stdin)["end"]["sum_received"]["bits_per_second"]/1e6))' 2>/dev/null)
  remote "pkill -x iperf3"
  info "iperf3, ${TPUT_SECS} s each way"
else
  # Fallback without iperf3: stream zeros through nc and time it.
  MB=$(( TPUT_SECS * 12 ))   # about TPUT_SECS seconds at 100 Mbps
  t0=$(python3 -c 'import time;print(time.time())')
  remote "nc -l $IMAC_IP 5201 >/dev/null & sleep 0.5" ; sleep 0.5
  dd if=/dev/zero bs=1048576 count=$MB 2>/dev/null | nc -N "$IMAC_IP" 5201 2>/dev/null || dd if=/dev/zero bs=1048576 count=$MB 2>/dev/null | nc "$IMAC_IP" 5201
  t1=$(python3 -c 'import time;print(time.time())')
  UP=$(python3 -c "print(round($MB*8*1.048576/($t1-$t0-0.5)))")
  nc -l "$HOST_IP" 5201 >/dev/null & LPID=$!; sleep 0.5
  t0=$(python3 -c 'import time;print(time.time())')
  remote "dd if=/dev/zero bs=1048576 count=$MB 2>/dev/null | nc -N $HOST_IP 5201"
  wait $LPID 2>/dev/null
  t1=$(python3 -c 'import time;print(time.time())')
  DOWN=$(python3 -c "print(round($MB*8*1.048576/($t1-$t0)))")
  info "nc fallback (iperf3 missing on one side), ${MB} MB each way"
fi
[ -n "${UP:-}" ] && mbps_check "MacBook -> iMac" "$UP" || fail "throughput MacBook -> iMac not measured"
[ -n "${DOWN:-}" ] && mbps_check "iMac -> MacBook" "$DOWN" || fail "throughput iMac -> MacBook not measured"

echo "== 6. Ports and firewall"
for p in 5001 5002; do
  lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1 && fail "MacBook port $p in use" || pass "MacBook port $p free"
  remote "lsof -nP -iTCP:$p -sTCP:LISTEN" >/dev/null 2>&1 && fail "iMac port $p in use" || pass "iMac port $p free"
done
FW=/usr/libexec/ApplicationFirewall/socketfilterfw
info "MacBook firewall: $($FW --getglobalstate 2>/dev/null | sed 's/^Firewall is //')"
info "iMac firewall:    $(remote "$FW --getglobalstate 2>/dev/null" | sed 's/^Firewall is //')"

echo "== 7. Native builds on each machine"
if swift build -q 2>/dev/null; then
  pass "MacBook build: $(.build/debug/RemoteMirrorHost) [$(file -b .build/debug/RemoteMirrorHost | awk '{print $NF}')]"
else fail "MacBook swift build failed"; fi
if remote "cd $IMAC_REPO && swift build -q" >/dev/null 2>&1; then
  pass "iMac build: $(remote "$IMAC_REPO/.build/debug/RemoteMirrorClient") [$(remote "file -b $IMAC_REPO/.build/debug/RemoteMirrorClient" | awk '{print $NF}')]"
else fail "iMac swift build failed"; fi

echo "== 9. Hardware video"
L_CAPS=$(.build/debug/RemoteMirrorHost --video-caps 2>/dev/null)
R_CAPS=$(remote "$IMAC_REPO/.build/debug/RemoteMirrorClient --video-caps" 2>/dev/null)
info "MacBook: $L_CAPS"
info "iMac:    $R_CAPS"
echo "$L_CAPS" | grep -q '"h264_encode_hw":true' && pass "MacBook hardware H.264 encode" || fail "MacBook has no hardware H.264 encode"
echo "$L_CAPS" | grep -q '"hevc_encode_hw":true' && pass "MacBook hardware HEVC encode" || warn "MacBook has no hardware HEVC encode"
echo "$R_CAPS" | grep -q '"h264_decode_hw":true' && pass "iMac hardware H.264 decode" || fail "iMac has no hardware H.264 decode"
echo "$R_CAPS" | grep -q '"hevc_decode_hw":true' && pass "iMac hardware HEVC decode" || warn "iMac has no hardware HEVC decode"

echo
if [ $FAILS -eq 0 ]; then echo "Gate 1: PASS ($WARNS warnings)"; exit 0
else echo "Gate 1: FAIL ($FAILS failed, $WARNS warnings)"; exit 1; fi
