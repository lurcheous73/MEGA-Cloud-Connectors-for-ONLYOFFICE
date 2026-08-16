#!/usr/bin/env bash
set -Eeuo pipefail

# BRIMSTONE CUSTOM CODE — deploy the already-built v0.003 file-upload DLL.
# This script NEVER rebuilds the candidate and preserves the current MEGA account.

MODE="${1:-preflight}"
REPO="${REPO:-/opt/mega-cloud-connectors-for-onlyoffice}"
C="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
DB="${MYSQL_CONTAINER:-onlyoffice-mysql-server}"
IMAGE="${IMAGE:-onlyoffice/communityserver:12.8.0.1971}"
CANDIDATE="${MEGA_S4_DLL:-/opt/communityserver-megas4-dev/web/studio/ASC.Web.Studio/bin/ASC.Files.Thirdparty.dll}"
LIVE_DLL="/var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll"
HANDLER="/var/www/onlyoffice/WebStudio/Products/Files/HttpHandlers/brimstone-megas4.ashx"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/mega-cloud-connectors-for-onlyoffice}"
STATE_DIR="${STATE_DIR:-/var/lib/mega-cloud-connectors-for-onlyoffice}"
STATE="$STATE_DIR/v0.003-file-upload.state"

EXPECTED_OLD="11864dfba74e7299b407439b54b4fc0fcfb3b7db32bb9526dd889b2476ae7c54"
EXPECTED_NEW="62bdff5b75ab9db37108a6f772a92240805879f0cf400bb8c2813d2aa68b679f"

fail(){ echo "FAIL: $*" >&2; exit 1; }
live_hash(){ docker exec "$C" sha256sum "$LIVE_DLL" | awk '{print $1}'; }
mysql_scalar(){
  local sql="$1"
  docker exec -e SQL="$sql" "$DB" sh -lc 'mysql --batch --raw --skip-column-names -uroot -p"$MYSQL_ROOT_PASSWORD" onlyoffice -e "$SQL"' 2>/dev/null | tr -d '\r'
}
mega_rows(){ mysql_scalar "SELECT COUNT(*) FROM files_thirdparty_account WHERE LOWER(provider)='megas4';"; }
mega_maps(){ mysql_scalar "SELECT COUNT(*) FROM files_thirdparty_id_mapping WHERE id LIKE 'sboxmega-%' OR id LIKE 'sbox-megas4-%' OR hash_id LIKE 'sboxmega-%' OR hash_id LIKE 'sbox-megas4-%';"; }

verify_candidate(){
  [[ -s "$CANDIDATE" ]] || fail "candidate missing: $CANDIDATE"
  local h dir
  h="$(sha256sum "$CANDIDATE" | awk '{print $1}')"
  [[ "$h" == "$EXPECTED_NEW" ]] || fail "candidate hash mismatch: expected $EXPECTED_NEW got $h"
  dir="$(dirname "$CANDIDATE")"

  docker run --rm -i --entrypoint /bin/bash -v "$dir:/candidate:ro" "$IMAGE" -s <<'CHECK'
set -euo pipefail
DLL=/candidate/ASC.Files.Thirdparty.dll
TYPES="$(monodis --typedef "$DLL")"
STRINGS="$(monodis --userstrings "$DLL")"
REFS="$(monodis --assemblyref "$DLL")"
grep -Fq 'ASC.Files.Thirdparty.MegaS4.MegaS4FileDao' <<<"$TYPES"
grep -Fq 'sboxmega-' <<<"$STRINGS"
grep -Fq 'ProviderFileDao converts third-party IDs' <<<"$STRINGS"
grep -Fq 'Name=AWSSDK.S3' <<<"$REFS"
grep -Fq 'Name=AWSSDK.Core' <<<"$REFS"
echo 'PASS: v0.003 candidate CLR contract verified'
CHECK

  echo "PASS: exact candidate hash $h"
}

preflight(){
  echo "============================================================"
  echo " BRIMSTONE MEGA S4 v0.003 — EXACT CANDIDATE PRE-FLIGHT"
  echo "============================================================"
  [[ -d "$REPO/.git" ]] || fail "repo missing: $REPO"
  [[ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" == "v0.003-file-upload" ]] || fail "checkout v0.003-file-upload first"
  [[ -z "$(git -C "$REPO" status --porcelain)" ]] || fail "repo worktree is not clean"
  docker inspect "$C" >/dev/null 2>&1 || fail "CommunityServer container missing"
  docker inspect "$DB" >/dev/null 2>&1 || fail "MySQL container missing"
  [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer not running"
  [[ "$(docker inspect -f '{{.State.Running}}' "$DB")" == "true" ]] || fail "MySQL not running"
  [[ "$(docker inspect -f '{{.Config.Image}}' "$C")" == "$IMAGE" ]] || fail "CommunityServer image mismatch"
  [[ "$(live_hash)" == "$EXPECTED_OLD" ]] || fail "unexpected live DLL: $(live_hash)"
  docker exec "$C" test -s "$HANDLER" || fail "existing Brimstone handler mapping missing"
  verify_candidate
  echo "INFO: MEGA rows currently: $(mega_rows)"
  echo "INFO: MEGA maps currently: $(mega_maps)"
  echo "PASS: exact v0.003 candidate is safe to deploy over v0.002"
}

restore(){
  local backup="$1"
  [[ -s "$backup/ASC.Files.Thirdparty.dll" ]] || fail "rollback DLL missing"
  [[ "$(sha256sum "$backup/ASC.Files.Thirdparty.dll" | awk '{print $1}')" == "$EXPECTED_OLD" ]] || fail "rollback DLL hash mismatch"
  docker stop "$C" >/dev/null || true
  docker cp "$backup/ASC.Files.Thirdparty.dll" "$C:$LIVE_DLL" >/dev/null
  docker start "$C" >/dev/null
  sleep 10
  [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer failed during rollback"
  [[ "$(live_hash)" == "$EXPECTED_OLD" ]] || fail "rollback live hash mismatch: $(live_hash)"
}

install(){
  preflight

  local before_rows before_maps stamp backup mutated=0
  before_rows="$(mega_rows)"
  before_maps="$(mega_maps)"
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="$BACKUP_ROOT/brimstone-mega-s4-v0.003-file-upload-$stamp"
  mkdir -p "$backup" "$STATE_DIR"
  chmod 700 "$backup" "$STATE_DIR"

  docker cp "$C:$LIVE_DLL" "$backup/ASC.Files.Thirdparty.dll" >/dev/null
  [[ "$(sha256sum "$backup/ASC.Files.Thirdparty.dll" | awk '{print $1}')" == "$EXPECTED_OLD" ]] || fail "backup hash mismatch"
  cat > "$backup/MANIFEST" <<EOF
BRIMSTONE=MEGA-S4-v0.003-file-upload
created=$stamp
old_dll=$EXPECTED_OLD
new_dll=$EXPECTED_NEW
candidate=$CANDIDATE
mega_rows_before=$before_rows
mega_maps_before=$before_maps
EOF
  (cd "$backup" && sha256sum ASC.Files.Thirdparty.dll MANIFEST > SHA256SUMS && sha256sum -c SHA256SUMS)

  rollback_on_error(){
    local rc=$?
    trap - ERR
    if [[ "$mutated" == "1" ]]; then
      echo "ERROR after DLL mutation — restoring v0.002 live DLL" >&2
      restore "$backup" || true
    fi
    exit "$rc"
  }
  trap rollback_on_error ERR

  echo
  echo "=== STOP COMMUNITYSERVER ==="
  docker stop "$C" >/dev/null
  mutated=1

  echo "=== INSTALL EXACT v0.003 CANDIDATE ==="
  docker cp "$CANDIDATE" "$C:$LIVE_DLL" >/dev/null

  echo "=== START COMMUNITYSERVER ==="
  docker start "$C" >/dev/null
  sleep 10

  [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer failed to return"
  [[ "$(live_hash)" == "$EXPECTED_NEW" ]] || fail "post-start DLL hash mismatch: $(live_hash)"
  [[ "$(mega_rows)" == "$before_rows" ]] || fail "MEGA provider row count changed: before=$before_rows after=$(mega_rows)"
  [[ "$(mega_maps)" == "$before_maps" ]] || fail "MEGA mapping count changed: before=$before_maps after=$(mega_maps)"
  docker exec "$C" test -s "$HANDLER" || fail "handler mapping disappeared"

  cat > "$STATE" <<EOF
backup=$backup
old_dll=$EXPECTED_OLD
new_dll=$EXPECTED_NEW
installed=$stamp
mega_rows=$before_rows
mega_maps=$before_maps
EOF
  chmod 600 "$STATE"

  trap - ERR
  mutated=0
  echo
  echo "============================================================"
  echo " PASS — v0.003 EXACT CANDIDATE DEPLOYED"
  echo "============================================================"
  echo "Live DLL : $(live_hash)"
  echo "Mega rows: $(mega_rows)"
  echo "Mega maps: $(mega_maps)"
  echo "Backup   : $backup"
}

status(){
  echo "Live DLL : $(live_hash 2>/dev/null || echo unavailable)"
  echo "Mega rows: $(mega_rows 2>/dev/null || echo unavailable)"
  echo "Mega maps: $(mega_maps 2>/dev/null || echo unavailable)"
  if [[ -s "$STATE" ]]; then cat "$STATE"; fi
}

rollback(){
  [[ -s "$STATE" ]] || fail "no v0.003 state file"
  [[ "$(live_hash)" == "$EXPECTED_NEW" ]] || fail "live DLL is not the v0.003 candidate"
  local backup expected_rows expected_maps
  backup="$(sed -n 's/^backup=//p' "$STATE" | head -n1)"
  expected_rows="$(sed -n 's/^mega_rows=//p' "$STATE" | head -n1)"
  expected_maps="$(sed -n 's/^mega_maps=//p' "$STATE" | head -n1)"
  [[ -d "$backup" ]] || fail "recorded backup missing: $backup"
  [[ "$(mega_rows)" == "$expected_rows" ]] || fail "MEGA row count changed since install; inspect before rollback"
  [[ "$(mega_maps)" == "$expected_maps" ]] || fail "MEGA mapping count changed since install; inspect before rollback"
  restore "$backup"
  rm -f "$STATE"
  echo "PASS: rolled back v0.003 candidate to v0.002"
  status
}

case "$MODE" in
  preflight) preflight ;;
  install) install ;;
  status) status ;;
  rollback) rollback ;;
  *) echo "Usage: $0 {preflight|install|status|rollback}" >&2; exit 2 ;;
esac
