#!/usr/bin/env bash
set -Eeuo pipefail

# BRIMSTONE CUSTOM CODE — warmup-aware ASHX discovery probe.
# Installs only a disposable canary, restarts CommunityServer only, waits for
# ONLYOFFICE warmup to complete, probes the canary, then removes it and restarts
# CommunityServer again so the live application is left clean.

REPO="${REPO:-/opt/mega-cloud-connectors-for-onlyoffice}"
C="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
HOST="${ONLYOFFICE_HOST:-work.brimstonecottage.uk}"
LIVE_DLL="/var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll"
EXPECTED_DLL="62bdff5b75ab9db37108a6f772a92240805879f0cf400bb8c2813d2aa68b679f"
SRC="$REPO/src/mega-s4/communityserver-12.8/ui/brimstone-megas4-canary.ashx"
DST="/var/www/onlyoffice/WebStudio/Products/Files/HttpHandlers/brimstone-megas4-canary.ashx"
CANARY_URL="https://127.0.0.1/Products/Files/HttpHandlers/brimstone-megas4-canary.ashx"
WARMUP_URL="https://127.0.0.1/api/2.0/warmup/progress.json"
RESTARTED=0

fail(){ echo "FAIL: $*" >&2; exit 1; }
live_hash(){ docker exec "$C" sha256sum "$LIVE_DLL" | awk '{print $1}'; }

wait_ready(){
  local label="$1"
  local tmp http body i
  tmp="$(mktemp)"
  echo "Waiting for ONLYOFFICE warmup: $label"

  for i in $(seq 1 60); do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null || true)" != "true" ]]; then
      sleep 3
      continue
    fi

    http="$(docker exec "$C" sh -lc "curl -ksS -o /tmp/brimstone-warmup-body -w '%{http_code}' -H 'Host: $HOST' '$WARMUP_URL'" 2>/dev/null || true)"
    : > "$tmp"
    docker cp "$C:/tmp/brimstone-warmup-body" "$tmp" >/dev/null 2>&1 || true
    docker exec "$C" rm -f /tmp/brimstone-warmup-body >/dev/null 2>&1 || true
    body="$(tr -d '\r\n' < "$tmp" 2>/dev/null || true)"

    if [[ "$http" == "200" ]] \
       && [[ "$body" != *"Please wait"* ]] \
       && [[ "$body" != *"<!DOCTYPE html"* ]] \
       && grep -Eqi 'Completed[^A-Za-z0-9]+(true|True)' "$tmp"; then
      echo "PASS: ONLYOFFICE warmup completed after $((i * 3))s"
      rm -f "$tmp"
      return 0
    fi

    if (( i % 5 == 0 )); then
      echo "INFO: still warming after $((i * 3))s (HTTP ${http:-none})"
    fi
    sleep 3
  done

  echo "Last warmup response:"
  cat "$tmp" || true
  echo
  rm -f "$tmp"
  return 1
}

cleanup(){
  local rc=$?
  trap - EXIT

  docker exec "$C" rm -f "$DST" >/dev/null 2>&1 || true

  if [[ "$RESTARTED" == "1" ]]; then
    echo
    echo "=== CLEANUP RESTART COMMUNITYSERVER ==="
    docker restart "$C" >/dev/null || true
    if wait_ready "cleanup"; then
      echo "Cleanup live DLL: $(live_hash 2>/dev/null || echo unavailable)"
    else
      echo "WARN: CommunityServer cleanup restart is still warming; container remains running"
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
echo " BRIMSTONE MEGA S4 v0.005 — WARMUP-AWARE ASHX CANARY"
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
echo "PASS: canary physically present"
echo "Canary SHA256: $DST_HASH"

echo
echo "=== RESTART COMMUNITYSERVER ONLY ==="
RESTARTED=1
docker restart "$C" >/dev/null
wait_ready "test restart" || fail "ONLYOFFICE did not complete warmup within 180 seconds"
[[ "$(live_hash)" == "$EXPECTED_DLL" ]] || fail "locked DLL changed across restart"
docker exec "$C" test -s "$DST" || fail "canary disappeared across restart"
echo "PASS: locked DLL unchanged after warmup"
echo "PASS: canary still present after warmup"

echo
echo "=== PROBE CANARY AFTER FULL WARMUP ==="
BODY="$(mktemp)"
HTTP="$(docker exec "$C" sh -lc "curl -ksS -o /tmp/brimstone-canary-ready-body -w '%{http_code}' -H 'Host: $HOST' '$CANARY_URL'" || true)"
docker cp "$C:/tmp/brimstone-canary-ready-body" "$BODY" >/dev/null 2>&1 || true
docker exec "$C" rm -f /tmp/brimstone-canary-ready-body >/dev/null 2>&1 || true

echo "Probe HTTP: $HTTP"
echo "Probe body:"
cat "$BODY" || true
echo

if [[ "$HTTP" == "200" ]] && grep -Fq '"brimstone":"ashx-canary"' "$BODY"; then
  rm -f "$BODY"
  echo
  echo "============================================================"
  echo " PASS — INLINE ASHX EXECUTES AFTER FULL WARMUP"
  echo "============================================================"
  echo "Conclusion: the previous 404 and startup-page results were discovery/warmup state."
  echo "The next safe step is an inline Brimstone bridge for the real MEGA handler route."
  exit 0
fi

rm -f "$BODY"
echo
fail "canary did not execute after full ONLYOFFICE warmup"
