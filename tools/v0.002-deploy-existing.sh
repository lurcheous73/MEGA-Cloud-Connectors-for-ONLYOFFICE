#!/usr/bin/env bash
set -Eeuo pipefail

# BRIMSTONE CUSTOM CODE — deploy the already-built v0.002 root-browse DLL.
# This script NEVER rebuilds the candidate.

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
STATE="$STATE_DIR/v0.002-root-browse.state"

EXPECTED_OLD="2e5b17bd0e3c7c216428e58e0163c1aacac707cbada4f49edd849daf80cdb787"
EXPECTED_NEW="11864dfba74e7299b407439b54b4fc0fcfb3b7db32bb9526dd889b2476ae7c54"

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
grep -Fq 'ASC.Files.Thirdparty.MegaS4.MegaS4DaoSelector' <<<"$TYPES"
grep -Fq 'ASC.Files.Thirdparty.MegaS4.MegaS4ProviderInfo' <<<"$TYPES"
grep -Fq 'sboxmega-' <<<"$STRINGS"
if grep -Fq 'sbox-megas4-' <<<"$STRINGS"; then
  echo 'FAIL: old sbox-megas4 prefix remains in candidate' >&2
  exit 1
fi
grep -Fq 'Name=AWSSDK.S3' <<<"$REFS"
grep -Fq 'Name=AWSSDK.Core' <<<"$REFS"
echo 'PASS: candidate CLR contract verified'
CHECK

  echo "PASS: exact candidate hash $h"
}

preflight(){
  echo "============================================================"
  echo " BRIMSTONE MEGA S4 v0.002 — EXACT CANDIDATE PRE-FLIGHT"
  echo "============================================================"
  [[ -d "$REPO/.git" ]] || fail "repo missing: $REPO"
  [[ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" == "v0.002-root-browse" ]] || fail "checkout v0.002-root-browse first"
  [[ -z "$(git -C "$REPO" status --porcelain)" ]] || fail "repo worktree is not clean"
  docker inspect "$C" >/dev/null 2>&1 || fail "CommunityServer container missing"
  docker inspect "$DB" >/dev/null 2>&1 || fail "MySQL container missing"
  [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer not running"
  [[ "$(docker inspect -f '{{.State.Running}}' "$DB")" == "true" ]] || fail "MySQL not running"
  [[ "$(docker inspect -f '{{.Config.Image}}' "$C")" == "$IMAGE" ]] || fail "CommunityServer image mismatch"
  [[ "$(live_hash)" == "$EXPECTED_OLD" ]] || fail "unexpected live DLL: $(live_hash)"
  [[ "$(mega_rows)" == "0" ]] || fail "MEGA provider rows exist"
  [[ "$(mega_maps)" == "0" ]] || fail "MEGA mapping rows exist"
  docker exec "$C" test -s "$HANDLER" || fail "existing Brimstone handler mapping missing"
  verify_candidate
  echo "PASS: exact candidate is safe to deploy"
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
  local stamp backup mutated=0
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="$BACKUP_ROOT/brimstone-mega-s4-v0.002-root-browse-$stamp"
  mkdir -p "$backup" "$STATE_DIR"
  chmod 700 "$backup" "$STATE_DIR"

  docker cp "$C:$LIVE_DLL" "$backup/ASC.Files.Thirdparty.dll" >/dev/null
  [[ "$(sha256sum "$backup/ASC.Files.Thirdparty.dll" | awk '{print $1}')" == "$EXPECTED_OLD" ]] || fail "backup hash mismatch"
  cat > "$backup/MANIFEST" <<EOF
BRIMSTONE=MEGA-S4-v0.002-root-browse
created=$stamp
old_dll=$EXPECTED_OLD
new_dll=$EXPECTED_NEW
candidate=$CANDIDATE
EOF
  (cd "$backup" && sha256sum ASC.Files.Thirdparty.dll MANIFEST > SHA256SUMS && sha256sum -c SHA256SUMS)

  rollback_on_error(){
    local rc=$?
    trap - ERR
    if [[ "$mutated" == "1" ]]; then
      echo "ERROR after DLL mutation — restoring previous live DLL" >&2
      restore "$backup" || true
    fi
    exit "$rc"
  }
  trap rollback_on_error ERR

  echo
  echo "=== STOP COMMUNITYSERVER ==="
  docker stop "$C" >/dev/null
  mutated=1

  echo "=== INSTALL EXACT v0.002 CANDIDATE ==="
  docker cp "$CANDIDATE" "$C:$LIVE_DLL" >/dev/null

  echo "=== START COMMUNITYSERVER ==="
  docker start "$C" >/dev/null
  sleep 10

  [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer failed to return"
  [[ "$(live_hash)" == "$EXPECTED_NEW" ]] || fail "post-start DLL hash mismatch: $(live_hash)"
  [[ "$(mega_rows)" == "0" ]] || fail "DB changed during deployment"
  [[ "$(mega_maps)" == "0" ]] || fail "MEGA mappings appeared during deployment"
  docker exec "$C" test -s "$HANDLER" || fail "handler mapping disappeared"

  cat > "$STATE" <<EOF
backup=$backup
old_dll=$EXPECTED_OLD
new_dll=$EXPECTED_NEW
installed=$stamp
EOF
  chmod 600 "$STATE"

  trap - ERR
  mutated=0
  echo
  echo "============================================================"
  echo " PASS — v0.002 EXACT CANDIDATE DEPLOYED"
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
  [[ -s "$STATE" ]] || fail "no v0.002 state file"
  [[ "$(live_hash)" == "$EXPECTED_NEW" ]] || fail "live DLL is not the v0.002 candidate"
  [[ "$(mega_rows)" == "0" ]] || fail "delete MEGA test connection before rollback"
  [[ "$(mega_maps)" == "0" ]] || fail "MEGA mappings exist; inspect before rollback"
  local backup
  backup="$(sed -n 's/^backup=//p' "$STATE" | head -n1)"
  [[ -d "$backup" ]] || fail "recorded backup missing: $backup"
  restore "$backup"
  rm -f "$STATE"
  echo "PASS: rolled back v0.002 candidate"
  status
}

case "$MODE" in
  preflight) preflight ;;
  install) install ;;
  status) status ;;
  rollback) rollback ;;
  *) echo "Usage: $0 {preflight|install|status|rollback}" >&2; exit 2 ;;
esac
