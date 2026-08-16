#!/usr/bin/env bash
set -Eeuo pipefail

# BRIMSTONE CUSTOM CODE — prove Mono/ASP.NET can compile and execute an inline
# .ashx handler in the SAME directory as the MEGA S4 route, without touching
# the live MEGA handler, DLL, DB or UI.

REPO="${REPO:-/opt/mega-cloud-connectors-for-onlyoffice}"
C="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
LIVE_DLL="/var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll"
EXPECTED_DLL="62bdff5b75ab9db37108a6f772a92240805879f0cf400bb8c2813d2aa68b679f"
SRC="$REPO/src/mega-s4/communityserver-12.8/ui/brimstone-megas4-canary.ashx"
DST="/var/www/onlyoffice/WebStudio/Products/Files/HttpHandlers/brimstone-megas4-canary.ashx"
URL="https://127.0.0.1/Products/Files/HttpHandlers/brimstone-megas4-canary.ashx"

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ -d "$REPO/.git" ]] || fail "repo missing: $REPO"
[[ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" == "v0.005-typed-creds" ]] || fail "checkout v0.005-typed-creds first"
[[ -z "$(git -C "$REPO" status --porcelain)" ]] || fail "repo worktree is not clean"
[[ -s "$SRC" ]] || fail "canary source missing: $SRC"
grep -Fq 'BRIMSTONE CUSTOM CODE' "$SRC" || fail "canary source marker missing"

docker inspect "$C" >/dev/null 2>&1 || fail "CommunityServer container missing"
[[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer is not running"

LIVE_HASH="$(docker exec "$C" sha256sum "$LIVE_DLL" | awk '{print $1}')"
[[ "$LIVE_HASH" == "$EXPECTED_DLL" ]] || fail "live DLL changed: $LIVE_HASH"

cleanup(){ docker exec "$C" rm -f "$DST" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "============================================================"
echo " BRIMSTONE MEGA S4 v0.005 — INLINE ASHX CANARY"
echo "============================================================"
echo "PASS: live DLL still locked at $LIVE_HASH"

echo
echo "=== INSTALL DISPOSABLE CANARY ==="
docker cp "$SRC" "$C:$DST" >/dev/null

echo
echo "=== PROBE INLINE HANDLER ==="
BODY="$(mktemp)"
trap 'rm -f "$BODY"; cleanup' EXIT
HTTP="$(docker exec "$C" sh -lc "curl -ksS -o /tmp/brimstone-canary-body -w '%{http_code}' -H 'Host: work.brimstonecottage.uk' '$URL'" || true)"
docker cp "$C:/tmp/brimstone-canary-body" "$BODY" >/dev/null 2>&1 || true
docker exec "$C" rm -f /tmp/brimstone-canary-body >/dev/null 2>&1 || true

echo "Probe HTTP: $HTTP"
echo "Probe body:"
cat "$BODY" || true
echo

if [[ "$HTTP" == "200" ]] && grep -Fq '"brimstone":"ashx-canary"' "$BODY"; then
  echo
  echo "============================================================"
  echo " PASS — INLINE ASHX HANDLER EXECUTION WORKS"
  echo "============================================================"
  echo "Conclusion: Mono can compile/execute .ashx in this directory."
  echo "The remaining fault is specific to resolving the compiled external handler"
  echo "through the @ WebHandler directive, not the DLL and not the route itself."
  exit 0
fi

echo
fail "inline ASHX canary did not execute; inspect the response above"
