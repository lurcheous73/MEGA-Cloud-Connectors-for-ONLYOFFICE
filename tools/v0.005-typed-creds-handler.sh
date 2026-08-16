#!/usr/bin/env bash
set -Eeuo pipefail

# BRIMSTONE CUSTOM CODE — v0.005 manual-credential bucket-helper handler fix.
# Changes ONLY the .ashx WebHandler directive. Does not touch DLLs or DB.

MODE="${1:-preflight}"
REPO="${REPO:-/opt/mega-cloud-connectors-for-onlyoffice}"
C="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
SOURCE_HANDLER="$REPO/src/mega-s4/communityserver-12.8/ui/brimstone-megas4.ashx"
LIVE_HANDLER="/var/www/onlyoffice/WebStudio/Products/Files/HttpHandlers/brimstone-megas4.ashx"
LIVE_DLL="/var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll"
EXPECTED_DLL="62bdff5b75ab9db37108a6f772a92240805879f0cf400bb8c2813d2aa68b679f"
OLD_DIRECTIVE='<%@ WebHandler Language="C#" Class="ASC.Files.Thirdparty.MegaS4.BrimstoneMegaS4Handler, ASC.Files.Thirdparty" %>'
NEW_DIRECTIVE='<%@ WebHandler Language="C#" Class="ASC.Files.Thirdparty.MegaS4.BrimstoneMegaS4Handler" %>'
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/mega-cloud-connectors-for-onlyoffice}"
STATE_DIR="${STATE_DIR:-/var/lib/mega-cloud-connectors-for-onlyoffice}"
STATE="$STATE_DIR/v0.005-typed-creds-handler.state"

fail(){ echo "FAIL: $*" >&2; exit 1; }
live_dll_hash(){ docker exec "$C" sha256sum "$LIVE_DLL" | awk '{print $1}'; }
live_handler(){ docker exec "$C" cat "$LIVE_HANDLER"; }

probe(){
  local body code
  body="$(mktemp)"
  code="$(docker exec "$C" sh -lc 'curl -ksS -X POST -H "Host: work.brimstonecottage.uk" --data "action=list-buckets" -o /tmp/brimstone-v0005-probe.body -w "%{http_code}" https://127.0.0.1/Products/Files/HttpHandlers/brimstone-megas4.ashx')" || {
    rm -f "$body"
    fail "local handler probe curl failed"
  }
  docker cp "$C:/tmp/brimstone-v0005-probe.body" "$body" >/dev/null
  docker exec "$C" rm -f /tmp/brimstone-v0005-probe.body >/dev/null 2>&1 || true

  echo "Probe HTTP: $code"
  echo "Probe body:"
  cat "$body"
  echo

  if grep -Fq '<title>Runtime Error</title>' "$body" || grep -Fq '<h1>Runtime Error</h1>' "$body"; then
    rm -f "$body"
    return 1
  fi
  if ! grep -Eq '^\{"ok":(true|false),' "$body"; then
    rm -f "$body"
    return 1
  fi
  rm -f "$body"
  return 0
}

preflight(){
  echo "============================================================"
  echo " BRIMSTONE MEGA S4 v0.005 — TYPED CREDS HANDLER PRE-FLIGHT"
  echo "============================================================"
  [[ -d "$REPO/.git" ]] || fail "repo missing: $REPO"
  [[ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" == "v0.005-typed-creds" ]] || fail "checkout v0.005-typed-creds first"
  [[ -z "$(git -C "$REPO" status --porcelain)" ]] || fail "repo worktree is not clean"
  docker inspect "$C" >/dev/null 2>&1 || fail "CommunityServer container missing"
  [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer not running"
  [[ "$(live_dll_hash)" == "$EXPECTED_DLL" ]] || fail "working v0.004/v0.003 DLL baseline changed: $(live_dll_hash)"
  [[ "$(cat "$SOURCE_HANDLER")" == "$NEW_DIRECTIVE" ]] || fail "source handler is not the v0.005 directive"
  local current
  current="$(live_handler)"
  if [[ "$current" == "$OLD_DIRECTIVE" ]]; then
    echo "PASS: live handler is the known broken pre-v0.005 directive"
  elif [[ "$current" == "$NEW_DIRECTIVE" ]]; then
    echo "INFO: corrected handler is already live"
  else
    fail "live handler content is unexpected; refusing to overwrite"
  fi
  echo "PASS: live DLL remains locked at $EXPECTED_DLL"
}

install(){
  preflight
  local current stamp backup
  current="$(live_handler)"
  if [[ "$current" == "$NEW_DIRECTIVE" ]]; then
    echo "INFO: corrected handler already installed; probing only"
    probe || fail "corrected handler still returns non-Brimstone response"
    echo "PASS: handler reaches Brimstone JSON"
    return
  fi

  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="$BACKUP_ROOT/brimstone-mega-s4-v0.005-typed-creds-handler-$stamp"
  mkdir -p "$backup" "$STATE_DIR"
  chmod 700 "$backup" "$STATE_DIR"
  docker cp "$C:$LIVE_HANDLER" "$backup/brimstone-megas4.ashx" >/dev/null
  printf '%s\n' "backup=$backup" "dll=$EXPECTED_DLL" "installed=$stamp" > "$STATE"
  chmod 600 "$STATE"

  echo
  echo "=== INSTALL CORRECTED .ASHX ONLY ==="
  docker cp "$SOURCE_HANDLER" "$C:$LIVE_HANDLER" >/dev/null
  [[ "$(live_handler)" == "$NEW_DIRECTIVE" ]] || {
    docker cp "$backup/brimstone-megas4.ashx" "$C:$LIVE_HANDLER" >/dev/null || true
    fail "handler copy verification failed; old handler restored"
  }

  echo
  echo "=== LOCAL HANDLER PROBE ==="
  if ! probe; then
    echo "FAIL: corrected directive still produced non-Brimstone response; restoring old handler" >&2
    docker cp "$backup/brimstone-megas4.ashx" "$C:$LIVE_HANDLER" >/dev/null
    rm -f "$STATE"
    exit 1
  fi

  [[ "$(live_dll_hash)" == "$EXPECTED_DLL" ]] || fail "DLL changed unexpectedly"
  echo
  echo "============================================================"
  echo " PASS — v0.005 HANDLER NOW REACHES BRIMSTONE JSON"
  echo "============================================================"
  echo "Live DLL unchanged: $(live_dll_hash)"
  echo "Backup: $backup"
}

status(){
  echo "Live DLL: $(live_dll_hash 2>/dev/null || echo unavailable)"
  echo "Live handler: $(live_handler 2>/dev/null || echo unavailable)"
  [[ -s "$STATE" ]] && cat "$STATE"
}

rollback(){
  [[ -s "$STATE" ]] || fail "no v0.005 handler state file"
  local backup
  backup="$(sed -n 's/^backup=//p' "$STATE" | head -n1)"
  [[ -s "$backup/brimstone-megas4.ashx" ]] || fail "backup handler missing"
  docker cp "$backup/brimstone-megas4.ashx" "$C:$LIVE_HANDLER" >/dev/null
  [[ "$(live_handler)" == "$OLD_DIRECTIVE" ]] || fail "rollback handler verification failed"
  [[ "$(live_dll_hash)" == "$EXPECTED_DLL" ]] || fail "DLL baseline changed during rollback"
  rm -f "$STATE"
  echo "PASS: restored pre-v0.005 handler; DLL was untouched"
}

case "$MODE" in
  preflight) preflight ;;
  install) install ;;
  status) status ;;
  rollback) rollback ;;
  *) echo "Usage: $0 {preflight|install|status|rollback}" >&2; exit 2 ;;
esac
