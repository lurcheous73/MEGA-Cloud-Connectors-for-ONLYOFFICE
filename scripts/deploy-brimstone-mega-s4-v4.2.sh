#!/usr/bin/env bash
set -Eeuo pipefail

# BRIMSTONE CUSTOM CODE — exact-hash DLL-only deployment for MEGA S4 v4.2.
# v4.2 changes only ASC.Files.Thirdparty.dll. The existing v4.1 UI overlay and
# brimstone-megas4.ashx mapping remain untouched.

MODE="${1:-status}"
REPO="${REPO:-/opt/mega-cloud-connectors-for-onlyoffice}"
C="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
DB="${MYSQL_CONTAINER:-onlyoffice-mysql-server}"
IMAGE="${IMAGE:-onlyoffice/communityserver:12.8.0.1971}"
CANDIDATE="${MEGA_S4_DLL:-/opt/communityserver-megas4-dev/web/studio/ASC.Web.Studio/bin/ASC.Files.Thirdparty.dll}"
LIVE_DLL="/var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll"
HANDLER_LIVE="/var/www/onlyoffice/WebStudio/Products/Files/HttpHandlers/brimstone-megas4.ashx"
VERIFY_SCRIPT="$REPO/scripts/verify-brimstone-mega-s4-v4.2-candidate.sh"

EXPECTED_OLD_DLL_HASH="a5d6698434ef9a18909aa6a2b42657472d832396a918ae648bee2c63255133d2"
EXPECTED_NEW_DLL_HASH="2e5b17bd0e3c7c216428e58e0163c1aacac707cbada4f49edd849daf80cdb787"
UI_MARKER="BRIMSTONE MEGA S4 LIVE EXTENSION v4.1"
HANDLER_CLASS="ASC.Files.Thirdparty.MegaS4.BrimstoneMegaS4Handler, ASC.Files.Thirdparty"

BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/mega-cloud-connectors-for-onlyoffice}"
STATE_DIR="${STATE_DIR:-/var/lib/mega-cloud-connectors-for-onlyoffice}"
STATE_FILE="$STATE_DIR/brimstone-mega-s4-v4.2.state"

fail(){ echo "FAIL: $*" >&2; exit 1; }
chash(){ docker exec "$C" sha256sum "$LIVE_DLL" | awk '{print $1}'; }

mysql_scalar(){
  local sql="$1"
  docker exec -e SQL="$sql" "$DB" sh -lc '
    mysql --batch --raw --skip-column-names -uroot -p"$MYSQL_ROOT_PASSWORD" onlyoffice -e "$SQL"
  ' 2>/dev/null | tr -d '\r'
}

mega_rows(){ mysql_scalar "SELECT COUNT(*) FROM files_thirdparty_account WHERE LOWER(provider)='megas4';"; }
old_maps(){ mysql_scalar "SELECT COUNT(*) FROM files_thirdparty_id_mapping WHERE id LIKE 'megas4-%' OR hash_id LIKE 'megas4-%';"; }

ui_v41_count(){
  docker exec "$C" sh -lc "
    find /var/www/onlyoffice -path '*/Products/Files/Controls/ThirdParty/thirdparty.js' -type f -print0 2>/dev/null;
    find /var/www/onlyoffice -path '*/App_Data/static/bundle/files/javascript/files-*.js' -type f -print0 2>/dev/null;
    find /var/www/onlyoffice/Data/bundle/files/javascript -maxdepth 1 -type f -name 'files-*.js' -print0 2>/dev/null
  " | python3 -c '
import sys
raw=sys.stdin.buffer.read().split(b"\0")
print(sum(1 for p in raw if p))
' >/dev/null 2>&1 || true

  docker exec -e MARKER="$UI_MARKER" "$C" sh -lc '
    count=0
    for f in \
      $(find /var/www/onlyoffice -path "*/Products/Files/Controls/ThirdParty/thirdparty.js" -type f -print 2>/dev/null) \
      $(find /var/www/onlyoffice -path "*/App_Data/static/bundle/files/javascript/files-*.js" -type f -print 2>/dev/null) \
      $(find /var/www/onlyoffice/Data/bundle/files/javascript -maxdepth 1 -type f -name "files-*.js" -print 2>/dev/null)
    do
      if grep -aFq "$MARKER" "$f"; then count=$((count+1)); fi
    done
    printf "%s\n" "$count"
  ' | tr -d '\r'
}

validate_runtime_baseline(){
  docker inspect "$C" >/dev/null 2>&1 || fail "CommunityServer container not found"
  docker inspect "$DB" >/dev/null 2>&1 || fail "MySQL container not found"
  [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer is not running"
  [[ "$(docker inspect -f '{{.State.Running}}' "$DB")" == "true" ]] || fail "MySQL is not running"
  [[ "$(docker inspect -f '{{.Config.Image}}' "$C")" == "$IMAGE" ]] || fail "CommunityServer image mismatch"

  local live
  live="$(chash)"
  [[ "$live" == "$EXPECTED_OLD_DLL_HASH" ]] || fail "live DLL is not expected v4 build: $live"

  [[ "$(mega_rows)" == "0" ]] || fail "MegaS4 provider rows exist; refusing DLL swap"
  [[ "$(old_maps)" == "0" ]] || fail "old megas4-* mappings exist; refusing DLL swap"

  docker exec "$C" test -s "$HANDLER_LIVE" || fail "Brimstone handler mapping is missing"
  docker exec -e NEEDLE="$HANDLER_CLASS" "$C" sh -lc 'grep -Fq "$NEEDLE" '"$HANDLER_LIVE" || fail "Brimstone handler mapping is not the expected class"

  local uic
  uic="$(ui_v41_count)"
  [[ "$uic" == "9" ]] || fail "expected 9 v4.1 UI copies, found $uic"
}

validate_candidate(){
  [[ -s "$CANDIDATE" ]] || fail "candidate DLL missing: $CANDIDATE"
  local h
  h="$(sha256sum "$CANDIDATE" | awk '{print $1}')"
  [[ "$h" == "$EXPECTED_NEW_DLL_HASH" ]] || fail "candidate DLL hash mismatch: $h"
  [[ -x "$VERIFY_SCRIPT" || -s "$VERIFY_SCRIPT" ]] || fail "candidate verifier missing: $VERIFY_SCRIPT"
  bash "$VERIFY_SCRIPT" >/tmp/brimstone-megas4-v42-verify.$$
  cat /tmp/brimstone-megas4-v42-verify.$$
  rm -f /tmp/brimstone-megas4-v42-verify.$$
}

preflight(){
  echo "============================================================"
  echo " BRIMSTONE MEGA S4 v4.2 — DLL-ONLY PRE-FLIGHT"
  echo "============================================================"
  [[ -d "$REPO/.git" ]] || fail "connector checkout missing: $REPO"
  [[ -z "$(git -C "$REPO" status --porcelain)" ]] || fail "connector worktree is not clean"
  validate_runtime_baseline
  echo "PASS: exact v4 runtime baseline, clean DB, handler and v4.1 UI"
  validate_candidate
  echo "============================================================"
  echo " PASS — BRIMSTONE MEGA S4 v4.2 PRE-FLIGHT GREEN"
  echo "============================================================"
}

restore_dll(){
  local backup="$1"
  [[ -s "$backup/ASC.Files.Thirdparty.dll" ]] || fail "rollback DLL missing: $backup/ASC.Files.Thirdparty.dll"
  [[ "$(sha256sum "$backup/ASC.Files.Thirdparty.dll" | awk '{print $1}')" == "$EXPECTED_OLD_DLL_HASH" ]] || fail "rollback DLL hash mismatch"

  if [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]]; then
    docker stop "$C" >/dev/null
  fi
  docker cp "$backup/ASC.Files.Thirdparty.dll" "$C:$LIVE_DLL" >/dev/null
  docker start "$C" >/dev/null
  sleep 10
  [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer failed to restart during rollback"
  [[ "$(chash)" == "$EXPECTED_OLD_DLL_HASH" ]] || fail "rollback live DLL hash mismatch: $(chash)"
}

install_v42(){
  preflight

  local stamp backup mutated=0
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="$BACKUP_ROOT/brimstone-mega-s4-v4.2-$stamp"
  mkdir -p "$backup" "$STATE_DIR"
  chmod 700 "$backup" "$STATE_DIR"

  docker cp "$C:$LIVE_DLL" "$backup/ASC.Files.Thirdparty.dll" >/dev/null
  [[ "$(sha256sum "$backup/ASC.Files.Thirdparty.dll" | awk '{print $1}')" == "$EXPECTED_OLD_DLL_HASH" ]] || fail "backup DLL hash mismatch"

  cat > "$backup/MANIFEST" <<EOF
BRIMSTONE=MEGA-S4-v4.2-DLL-only
created=$stamp
old_dll=$EXPECTED_OLD_DLL_HASH
new_dll=$EXPECTED_NEW_DLL_HASH
candidate=$CANDIDATE
ui_marker=$UI_MARKER
handler=$HANDLER_LIVE
EOF
  (cd "$backup" && sha256sum ASC.Files.Thirdparty.dll MANIFEST > SHA256SUMS && sha256sum -c SHA256SUMS)

  rollback_on_error(){
    local rc=$?
    trap - ERR
    if [[ "$mutated" == "1" ]]; then
      echo "ERROR after DLL mutation — restoring v4 DLL..." >&2
      restore_dll "$backup" || true
      local restored
      restored="$(chash 2>/dev/null || true)"
      if [[ "$restored" == "$EXPECTED_OLD_DLL_HASH" ]]; then
        echo "AUTO-ROLLBACK PASS: $restored" >&2
      else
        echo "AUTO-ROLLBACK WARNING: live hash $restored" >&2
      fi
    fi
    exit "$rc"
  }
  trap rollback_on_error ERR

  echo
  echo "=== STOP COMMUNITYSERVER ==="
  docker stop "$C" >/dev/null
  [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "false" ]] || fail "CommunityServer did not stop"
  mutated=1

  echo "=== INSTALL EXACT BRIMSTONE v4.2 DLL ==="
  docker cp "$CANDIDATE" "$C:$LIVE_DLL" >/dev/null

  echo "=== START COMMUNITYSERVER ==="
  docker start "$C" >/dev/null
  sleep 10
  [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer failed to start"
  [[ "$(chash)" == "$EXPECTED_NEW_DLL_HASH" ]] || fail "post-start DLL hash mismatch: $(chash)"

  [[ "$(mega_rows)" == "0" ]] || fail "database changed during DLL deployment"
  [[ "$(old_maps)" == "0" ]] || fail "old mappings appeared during DLL deployment"
  docker exec "$C" test -s "$HANDLER_LIVE" || fail "handler mapping disappeared during deployment"
  [[ "$(ui_v41_count)" == "9" ]] || fail "v4.1 UI state changed during DLL deployment"

  cat > "$STATE_FILE" <<EOF
backup=$backup
old_dll=$EXPECTED_OLD_DLL_HASH
new_dll=$EXPECTED_NEW_DLL_HASH
installed=$stamp
EOF
  chmod 600 "$STATE_FILE"

  trap - ERR
  mutated=0

  echo
  echo "============================================================"
  echo " PASS — BRIMSTONE MEGA S4 v4.2 DLL DEPLOYED"
  echo "============================================================"
  echo "Live DLL : $(chash)"
  echo "UI       : unchanged (v4.1, 9/9)"
  echo "Handler  : unchanged"
  echo "Mega rows: $(mega_rows)"
  echo "Old maps : $(old_maps)"
  echo "Backup   : $backup"
  echo "============================================================"
}

status(){
  local live ui handler state
  live="$(chash 2>/dev/null || echo unavailable)"
  ui="$(ui_v41_count 2>/dev/null || echo unavailable)"
  handler="missing"; docker exec "$C" test -s "$HANDLER_LIVE" >/dev/null 2>&1 && handler="present"
  state="UNKNOWN"
  [[ "$live" == "$EXPECTED_OLD_DLL_HASH" ]] && state="BRIMSTONE MEGA S4 v4"
  [[ "$live" == "$EXPECTED_NEW_DLL_HASH" ]] && state="BRIMSTONE MEGA S4 v4.2"
  echo "Live DLL : $live"
  echo "State    : $state"
  echo "Handler  : $handler"
  echo "UI v4.1 : $ui/9 marked"
  echo "Mega rows: $(mega_rows 2>/dev/null || echo unavailable)"
  echo "Old maps : $(old_maps 2>/dev/null || echo unavailable)"
  if [[ -s "$STATE_FILE" ]]; then grep '^backup=' "$STATE_FILE" | sed 's/^backup=/Backup   : /'; fi
}

rollback(){
  [[ -s "$STATE_FILE" ]] || fail "no v4.2 state file found: $STATE_FILE"
  local backup live
  backup="$(sed -n 's/^backup=//p' "$STATE_FILE" | head -n1)"
  [[ -n "$backup" && -d "$backup" ]] || fail "recorded backup is missing: $backup"
  live="$(chash)"
  [[ "$live" == "$EXPECTED_NEW_DLL_HASH" ]] || fail "live DLL is not v4.2; refusing rollback: $live"
  [[ "$(mega_rows)" == "0" ]] || fail "MegaS4 provider rows exist; refusing automatic rollback"
  [[ "$(old_maps)" == "0" ]] || fail "old MEGA mappings exist; refusing automatic rollback"
  restore_dll "$backup"
  rm -f "$STATE_FILE"
  echo "PASS — rolled back BRIMSTONE MEGA S4 v4.2 DLL to v4"
  status
}

case "$MODE" in
  preflight) preflight ;;
  install) install_v42 ;;
  status) status ;;
  rollback) rollback ;;
  *) echo "Usage: $0 {preflight|install|status|rollback}" >&2; exit 2 ;;
esac
