#!/usr/bin/env bash
# THROWAWAY spike driver. Validates the streaming WS-bridge in a Kong dev env.
#
# Prereqs (run in your Kong/OpenResty dev environment — NOT this repo container):
#   1. Start the mocks:
#        cd ../mocks && mkdir -p logs && openresty -p "$PWD" -c nginx.conf
#   2. Start Kong DB-less with the spike plugin on the package path:
#        cd ../run
#        KONG_LUA_PACKAGE_PATH="$(cd .. && pwd)/?.lua;;" \
#          kong start -c kong.conf
#   3. Run this script:
#        ./test.sh
#
set -uo pipefail
BASE="${BASE:-http://127.0.0.1:8000}"

stamp() { while IFS= read -r l; do printf '%s  %s\n' "$(date +%T.%3N)" "$l"; done; }

echo "=============================================================="
echo "STEP 1 (GATE): incremental output from access phase"
echo "  PASS = 5 lines arrive ~300ms apart, NOT all at once at the end."
echo "--------------------------------------------------------------"
curl -sN "$BASE/spike/static" | stamp
echo

echo "=============================================================="
echo "STEP 2: streamed upstream SSE passthrough"
echo "  PASS = tok1..tok8 arrive incrementally (~250ms apart)."
echo "--------------------------------------------------------------"
curl -sN "$BASE/spike/upstream" | stamp
echo

echo "=============================================================="
echo "STEP 3: outbound WS round-trip from access"
echo "  PASS = 4 ws-echo lines reflecting the sent payloads."
echo "--------------------------------------------------------------"
curl -sN "$BASE/spike/ws" | stamp
echo

echo "=============================================================="
echo "STEP 4: full duplex hold-back bridge (clean)"
echo "  PASS = chunks arrive after a 1-chunk lookahead delay; even-numbered"
echo "         chunks are UPPERCASED (proves modification flows through)."
echo "--------------------------------------------------------------"
curl -sN "$BASE/spike/bridge" | stamp
echo

echo "=============================================================="
echo "STEP 5: block scenario — HOLD-BACK SAFETY ASSERTION"
echo "  PASS = a 'blocked' event appears AND 'tok3' never reaches the client."
echo "--------------------------------------------------------------"
out="$(curl -sN "$BASE/spike/bridge-block")"
echo "$out" | stamp
echo "--------------------------------------------------------------"
if echo "$out" | grep -q "tok3"; then
  echo "RESULT: FAIL — blocked chunk 'tok3' leaked to the client!"
  exit 1
elif echo "$out" | grep -qi "blocked"; then
  echo "RESULT: PASS — blocked chunk withheld; block event delivered."
else
  echo "RESULT: INCONCLUSIVE — no block event seen; check mock/Kong logs."
  exit 1
fi
