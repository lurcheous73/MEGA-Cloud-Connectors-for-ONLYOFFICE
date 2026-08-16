#!/usr/bin/env bash
set -Eeuo pipefail

# BRIMSTONE CUSTOM CODE — test whether the running Mono ASP.NET application
# needs an app/container restart before it discovers a newly-added .ashx file.
# This does NOT touch the real MEGA handler, DB, UI or locked provider DLL.

REPO="${REPO:-/opt/mega-cloud-connectors-for-onlyoffice}"
C="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
LIVE_DLL="/var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll"
EXPECTED_DLL="62bdff5b75ab9db37108a6f772a92240805879f0cf400bb8c2813d2aa68b679f"
SRC="$REPO/src/mega-s4/communityserver-12.8/ui/brimstone-megas4-canary.ashx"
DST="/var/www/onlyoffice/WebStudio/Products/Files/HttpHandlers/brimstone-megas4-canary.ashx"
URL="https://127.0.0.1/Products/Files/HttpHandlers/brimstone-megas4-canary.ashx"
HOST="work.brimstonecottage.uk"
RESTARTED=0

fail(){ echo "FAIL: $*" >&2; exit 1; }
live_hash(){ docker exec "$C" sha256sum "$LIVE_DLL" | awk '{print $1}'; }

cleanup(){
  local rc=$?
  trap - EXIT
  docker exec "$C" rm -f "$DST" >/dev/null 2>&1 || true
  if [[ "$RESTARTED" == "1" ]]; then
    echo
    echo "=== CLEANUP RESTART COMMUNITYSERVER ==="
    docker restart "$C" >/dev/null || true
    sleep 12
    if [[ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null || true)" == "true" ]]; then
      local h
      h="$(live_hash 2>/dev/null || true)"
      echo "Cleanup live DLL: ${h:-unavailable}"
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT

[[ -d "$REPO/.git" ]] || fail "repo missing: $REPO"
[[ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" == "v0.005-typed-creds" ]] || fail "checkout v0.005-typed-creds first"
[[ -z "$(git -C "$REPO" status --porcelain)" ]] || fail "repo worktree is not clean"
[[ -s "$SRC" ]] || fail "canary source missing: $SRC"
grep -Fq 'BRIMSTONE CUSTOM CODE' "$SRC" || fail "canary marker missing"

docker inspect "$C" >/dev/null 2>&1 || fail "CommunityServer container missing"
[[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer is not running"
[[ "$(live_hash)" == "$EXPECTED_DLL" ]] || fail "live DLL is not the locked v0.004/v0.005 baseline"

echo "============================================================"
echo " BRIMSTONE MEGA S4 v0.005 — ASHX DISCOVERY RESTART PROBE"
echo "============================================================"
echo "PASS: live DLL locked at $EXPECTED_DLL"

echo
echo "=== INSTALL DISPOSABLE CANARY ==="
docker exec "$C" rm -f "$DST"
docker cp "$SRC" "$C:$DST" >/dev/null
docker exec "$C" test -s "$DST" || fail "canary did not land in live handler directory"

SRC_HASH="$(sha256sum "$SRC" | awk '{print $1}')"
DST_HASH="$(docker exec "$C" sha256sum "$DST" | awk '{print $1}')"
[[ "$SRC_HASH" == "$DST_HASH" ]] || fail "canary copy hash mismatch"
echo "PASS: canary physically present before restart"
echo "Canary SHA256: $DST_HASH"
docker exec "$C" ls -l "$DST"

echo
echo "=== RESTART COMMUNITYSERVER ONLY ==="
RESTARTED=1
docker restart "$C" >/dev/null
sleep 15
[[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer did not return after restart"
[[ "$(live_hash)" == "$EXPECTED_DLL" ]] || fail "locked DLL changed across restart"
docker exec "$C" test -s "$DST" || fail "canary disappeared across restart"
echo "PASS: canary still present after restart"
echo "PASS: locked DLL unchanged after restart"

echo
echo "=== PROBE CANARY AFTER RESTART ==="
BODY="$(mktemp)"
HTTP="$(docker exec "$C" sh -lc "curl -ksS -o /tmp/brimstone-canary-restart-body -w '%{http_code}' -H 'Host: $HOST' '$URL'" || true)"
docker cp "$C:/tmp/brimstone-canary-restart-body" "$BODY" >/dev/null 2>&1 || true
docker exec "$C" rm -f /tmp/brimstone-canary-restart-body >/dev/null 2>&1 || true

echo "Probe HTTP: $HTTP"
echo "Probe body:"
cat "$BODY" || true
echo

if [[ "$HTTP" == "200" ]] && grep -Fq '"brimstone":"ashx-canary"' "$BODY"; then
  rm -f "$BODY"
  echo
  echo "============================================================"
  echo " PASS — RESTART MAKES NEW ASHX DISCOVERABLE"
  echo "============================================================"
  echo "Conclusion: the earlier 404 was app-domain/file-discovery state."
  echo "Next test should replace the real handler, restart CommunityServer,"
  echo "then probe typed credentials — with automatic rollback on failure."
  exit 0
fi

rm -f "$BODY"
echo
fail "canary still did not execute after CommunityServer restart"
