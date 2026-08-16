#!/usr/bin/env bash
set -Eeuo pipefail

# BRIMSTONE CUSTOM CODE — exact-hash live deployment for MEGA S4 v4.
MODE="${1:-status}"
REPO="${REPO:-/opt/mega-cloud-connectors-for-onlyoffice}"
C="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
DB="${MYSQL_CONTAINER:-onlyoffice-mysql-server}"
IMAGE="${IMAGE:-onlyoffice/communityserver:12.8.0.1971}"
CANDIDATE="${MEGA_S4_DLL:-/opt/communityserver-megas4-dev/web/studio/ASC.Web.Studio/bin/ASC.Files.Thirdparty.dll}"
LIVE_DLL="/var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll"
HANDLER_LIVE="/var/www/onlyoffice/WebStudio/Products/Files/HttpHandlers/brimstone-megas4.ashx"
OVERLAY="$REPO/src/mega-s4/communityserver-12.8/ui/brimstone-mega-s4-v4-overlay.js"
HANDLER_SOURCE="$REPO/src/mega-s4/communityserver-12.8/ui/brimstone-megas4.ashx"

REQUIRED_SOURCE_COMMIT="686e122e8b1eb3c2fd3b7cb64aa96b4309fbdaf8"
EXPECTED_OLD_DLL_HASH="3540c74cde53997e680846bd05c86eedbb678d544f16f56de5fbe916393037f2"
EXPECTED_NEW_DLL_HASH="a5d6698434ef9a18909aa6a2b42657472d832396a918ae648bee2c63255133d2"
V2_MARKER="MEGA S4 LIVE EXTENSION v2"
V4_MARKER="BRIMSTONE MEGA S4 LIVE EXTENSION v4"
SENTINEL="BRIMSTONE:S3COMPATIBLE:IMPORT"

BACKUP_ROOT="/var/backups/mega-cloud-connectors-for-onlyoffice"
STATE_DIR="/var/lib/mega-cloud-connectors-for-onlyoffice"
STATE_FILE="$STATE_DIR/brimstone-mega-s4-v4.state"

fail(){ echo "FAIL: $*" >&2; exit 1; }
chash(){ docker exec "$C" sha256sum "$LIVE_DLL" | awk '{print $1}'; }

mega_rows(){
  docker exec "$DB" sh -lc '
    mysql --batch --raw --skip-column-names -uroot -p"$MYSQL_ROOT_PASSWORD" onlyoffice \
      -e "SELECT COUNT(*) FROM files_thirdparty_account WHERE LOWER(provider)=\"megas4\";"
  ' 2>/dev/null | tr -d '\r'
}

old_maps(){
  docker exec "$DB" sh -lc '
    mysql --batch --raw --skip-column-names -uroot -p"$MYSQL_ROOT_PASSWORD" onlyoffice \
      -e "SELECT COUNT(*) FROM files_thirdparty_id_mapping WHERE id LIKE \"megas4-%\" OR hash_id LIKE \"megas4-%\";"
  ' 2>/dev/null | tr -d '\r'
}

discover_ui(){
  mapfile -t SOURCES < <(docker exec "$C" sh -lc "find /var/www/onlyoffice -path '*/Products/Files/Controls/ThirdParty/thirdparty.js' -type f -print | sort" | tr -d '\r')
  mapfile -t BUNDLES < <(docker exec "$C" sh -lc "find /var/www/onlyoffice -path '*/App_Data/static/bundle/files/javascript/files-*.js' -type f -print | sort; find /var/www/onlyoffice/Data/bundle/files/javascript -maxdepth 1 -type f -name 'files-*.js' -print | sort" | tr -d '\r')
  [[ "${#SOURCES[@]}" -ge 1 ]] || fail "no Files ThirdParty source JS found"
  [[ "${#BUNDLES[@]}" -ge 2 ]] || fail "expected static and Data/bundle Files JS copies"
}

validate_sources(){
  test -d "$REPO/.git" || fail "connector checkout missing: $REPO"
  git -C "$REPO" merge-base --is-ancestor "$REQUIRED_SOURCE_COMMIT" HEAD \
    || fail "checkout does not contain reviewed Brimstone v4 source commit $REQUIRED_SOURCE_COMMIT"
  [[ -z "$(git -C "$REPO" status --porcelain)" ]] || fail "connector worktree is not clean"

  test -s "$OVERLAY" || fail "v4 overlay missing: $OVERLAY"
  test -s "$HANDLER_SOURCE" || fail "handler source missing: $HANDLER_SOURCE"
  [[ "$(grep -cF "$V4_MARKER" "$OVERLAY")" -eq 1 ]] || fail "v4 overlay marker invalid"
  grep -Fq "$SENTINEL" "$OVERLAY" || fail "v4 shared import sentinel absent from overlay"
  grep -Fq 'Import existing S3-Compatible backup credentials' "$OVERLAY" || fail "shared-import UI missing"
  grep -Fq 'Pull buckets' "$OVERLAY" || fail "bucket discovery UI missing"
  grep -Fq 'Bucket name' "$OVERLAY" || fail "bucket-name field missing"
  grep -Fq 'Secret key' "$OVERLAY" || fail "secret-key field missing"
  grep -Fq 'ASC.Files.Thirdparty.MegaS4.BrimstoneMegaS4Handler, ASC.Files.Thirdparty' "$HANDLER_SOURCE" || fail "handler class contract invalid"
}

validate_candidate(){
  test -s "$CANDIDATE" || fail "candidate DLL missing: $CANDIDATE"
  local h dir base
  h="$(sha256sum "$CANDIDATE" | awk '{print $1}')"
  [[ "$h" == "$EXPECTED_NEW_DLL_HASH" ]] || fail "candidate DLL hash mismatch: $h"
  dir="$(dirname "$CANDIDATE")"; base="$(basename "$CANDIDATE")"
  docker run --rm -i --entrypoint /bin/bash -e DLL_BASE="$base" -v "$dir:/candidate:ro" "$IMAGE" <<'VERIFY'
set -euo pipefail
DLL="/candidate/$DLL_BASE"
monodis --assembly "$DLL" | grep -q 'Name:          ASC.Files.Thirdparty'
TYPES="$(monodis --typedef "$DLL")"
printf '%s\n' "$TYPES" | grep -Fq 'ASC.Files.Thirdparty.MegaS4.MegaS4DaoSelector'
printf '%s\n' "$TYPES" | grep -Fq 'ASC.Files.Thirdparty.MegaS4.BrimstoneMegaS4Secrets'
printf '%s\n' "$TYPES" | grep -Fq 'ASC.Files.Thirdparty.MegaS4.BrimstoneMegaS4Handler'
monodis --userstrings "$DLL" | grep -Fq 'BRIMSTONE:S3COMPATIBLE:IMPORT'
monodis --userstrings "$DLL" | grep -Fq 'sbox-megas4-'
VERIFY
  echo "PASS: exact v4 DLL hash and Brimstone CLR markers"
}

preflight(){
  echo "============================================================"
  echo " BRIMSTONE MEGA S4 v4 — EXACT-HASH PRE-FLIGHT"
  echo "============================================================"
  validate_sources
  validate_candidate

  docker inspect "$C" >/dev/null 2>&1 || fail "CommunityServer missing"
  docker inspect "$DB" >/dev/null 2>&1 || fail "MySQL missing"
  [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer is not running"
  [[ "$(docker inspect -f '{{.State.Running}}' "$DB")" == "true" ]] || fail "MySQL is not running"
  [[ "$(docker inspect -f '{{.Config.Image}}' "$C")" == "$IMAGE" ]] || fail "CommunityServer image mismatch"
  [[ "$(chash)" == "$EXPECTED_OLD_DLL_HASH" ]] || fail "live DLL is not expected provider-contract build: $(chash)"
  echo "PASS: exact provider-contract live DLL"

  [[ "$(mega_rows)" == "0" ]] || fail "MegaS4 provider rows exist; refusing v4 deployment"
  [[ "$(old_maps)" == "0" ]] || fail "old megas4-* mappings exist; refusing v4 deployment"
  echo "PASS: database clean for provider-contract upgrade"

  discover_ui
  local f
  for f in "${SOURCES[@]}" "${BUNDLES[@]}"; do
    [[ "$(docker exec "$C" grep -aFc "$V2_MARKER" "$f")" -eq 1 ]] || fail "v2 marker missing/duplicate in $f"
    [[ "$(docker exec "$C" grep -aFc "$V4_MARKER" "$f")" -eq 0 ]] || fail "v4 overlay already present in $f"
    if docker exec "$C" test -f "$f.gz"; then
      docker exec "$C" gzip -t "$f.gz" || fail "invalid gzip before deployment: $f.gz"
    fi
  done
  echo "PASS: v2 UI baseline present; v4 not yet installed"
  echo "============================================================"
  echo " PASS — BRIMSTONE MEGA S4 v4 PRE-FLIGHT GREEN"
  echo "============================================================"
}

restore_backup(){
  local backup="$1"
  local handler_existed="$2"
  set +e
  if [[ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" != "true" ]]; then docker start "$C" >/dev/null 2>&1; sleep 5; fi

  if [[ -s "$backup/files.tar.gz" ]]; then
    docker cp "$backup/files.tar.gz" "$C:/tmp/brimstone-v4-rollback.tar.gz" >/dev/null 2>&1
    docker exec "$C" tar -C / -xzf /tmp/brimstone-v4-rollback.tar.gz >/dev/null 2>&1
    docker exec "$C" rm -f /tmp/brimstone-v4-rollback.tar.gz >/dev/null 2>&1
  fi
  if [[ "$handler_existed" == "0" ]]; then docker exec "$C" rm -f "$HANDLER_LIVE" >/dev/null 2>&1; fi

  docker stop "$C" >/dev/null 2>&1
  docker cp "$backup/ASC.Files.Thirdparty.dll" "$C:$LIVE_DLL" >/dev/null 2>&1
  docker start "$C" >/dev/null 2>&1
  sleep 10
  set -e
}

install_v4(){
  preflight

  local stamp backup stage remote_tar mutated=0 handler_existed=0
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="$BACKUP_ROOT/brimstone-mega-s4-v4-$stamp"
  stage="$(mktemp -d /tmp/brimstone-mega-s4-v4.XXXXXX)"
  remote_tar="/tmp/brimstone-mega-s4-v4-backup-$stamp.tar.gz"
  mkdir -p "$backup" "$STATE_DIR"
  chmod 700 "$backup" "$STATE_DIR"

  cleanup_stage(){ rm -rf "$stage"; }
  trap cleanup_stage EXIT

  docker cp "$C:$LIVE_DLL" "$backup/ASC.Files.Thirdparty.dll" >/dev/null
  [[ "$(sha256sum "$backup/ASC.Files.Thirdparty.dll" | awk '{print $1}')" == "$EXPECTED_OLD_DLL_HASH" ]] || fail "backup DLL hash mismatch"

  discover_ui
  local f
  FILES=()
  for f in "${SOURCES[@]}" "${BUNDLES[@]}"; do
    FILES+=("$f")
    if docker exec "$C" test -f "$f.gz"; then FILES+=("$f.gz"); fi
  done
  if docker exec "$C" test -f "$HANDLER_LIVE"; then FILES+=("$HANDLER_LIVE"); handler_existed=1; fi

  printf '%s\n' "${FILES[@]}" > "$backup/files.list"
  REL=(); for f in "${FILES[@]}"; do REL+=("${f#/}"); done
  docker exec "$C" tar -C / -czf "$remote_tar" "${REL[@]}"
  docker cp "$C:$remote_tar" "$backup/files.tar.gz" >/dev/null
  docker exec "$C" rm -f "$remote_tar"
  tar -tzf "$backup/files.tar.gz" >/dev/null

  cat > "$backup/MANIFEST" <<EOF
BRIMSTONE=MEGA-S4-v4
created=$stamp
old_dll=$EXPECTED_OLD_DLL_HASH
new_dll=$EXPECTED_NEW_DLL_HASH
candidate=$CANDIDATE
handler_existed=$handler_existed
v4_marker=$V4_MARKER
EOF
  sha256sum "$backup/ASC.Files.Thirdparty.dll" "$backup/files.tar.gz" > "$backup/SHA256SUMS"
  (cd "$backup" && sha256sum -c SHA256SUMS)

  echo
  echo "=== BUILD PATCHED UI COPIES OFF-LINE ==="
  for f in "${SOURCES[@]}" "${BUNDLES[@]}"; do
    mkdir -p "$stage$(dirname "$f")"
    docker cp "$C:$f" "$stage$f" >/dev/null
    printf '\n\n' >> "$stage$f"
    cat "$OVERLAY" >> "$stage$f"
    [[ "$(grep -aFc "$V4_MARKER" "$stage$f")" -eq 1 ]] || fail "staged v4 marker validation failed: $f"
    if docker exec "$C" test -f "$f.gz"; then gzip -c "$stage$f" > "$stage$f.gz"; gzip -t "$stage$f.gz"; fi
  done
  mkdir -p "$stage$(dirname "$HANDLER_LIVE")"
  cp "$HANDLER_SOURCE" "$stage$HANDLER_LIVE"

  rollback_on_error(){
    local rc=$?
    trap - ERR
    if [[ "$mutated" == "1" ]]; then
      echo "ERROR after live mutation — restoring complete v2/provider-contract backup..." >&2
      restore_backup "$backup" "$handler_existed" || true
      local restored="$(chash 2>/dev/null || true)"
      if [[ "$restored" == "$EXPECTED_OLD_DLL_HASH" ]]; then echo "AUTO-ROLLBACK PASS: $restored" >&2; else echo "AUTO-ROLLBACK WARNING: live hash $restored" >&2; fi
    fi
    exit "$rc"
  }
  trap rollback_on_error ERR

  echo
  echo "=== STOP COMMUNITYSERVER ==="
  docker stop "$C" >/dev/null
  [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "false" ]] || fail "CommunityServer did not stop"
  mutated=1

  echo "=== INSTALL BRIMSTONE v4 DLL ==="
  docker cp "$CANDIDATE" "$C:$LIVE_DLL" >/dev/null

  echo "=== INSTALL BRIMSTONE HANDLER ==="
  docker cp "$stage$HANDLER_LIVE" "$C:$HANDLER_LIVE" >/dev/null

  echo "=== INSTALL BRIMSTONE v4 UI ==="
  for f in "${SOURCES[@]}" "${BUNDLES[@]}"; do
    docker cp "$stage$f" "$C:$f" >/dev/null
    if [[ -s "$stage$f.gz" ]]; then docker cp "$stage$f.gz" "$C:$f.gz" >/dev/null; fi
  done

  echo "=== START COMMUNITYSERVER ==="
  docker start "$C" >/dev/null
  sleep 10
  [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer failed to start"
  [[ "$(chash)" == "$EXPECTED_NEW_DLL_HASH" ]] || fail "post-start DLL hash mismatch: $(chash)"

  local handler_expected handler_live
  handler_expected="$(sha256sum "$HANDLER_SOURCE" | awk '{print $1}')"
  handler_live="$(docker exec "$C" sha256sum "$HANDLER_LIVE" | awk '{print $1}')"
  [[ "$handler_live" == "$handler_expected" ]] || fail "handler hash mismatch after start"

  for f in "${SOURCES[@]}" "${BUNDLES[@]}"; do
    [[ "$(docker exec "$C" grep -aFc "$V4_MARKER" "$f")" -eq 1 ]] || fail "v4 marker missing/duplicate after start: $f"
    if docker exec "$C" test -f "$f.gz"; then
      docker exec "$C" sh -lc "gzip -t '$f.gz' && gzip -dc '$f.gz' | cmp - '$f'" || fail "gzip mismatch after start: $f.gz"
    fi
  done
  [[ "$(mega_rows)" == "0" ]] || fail "database changed during deployment"
  [[ "$(old_maps)" == "0" ]] || fail "old mappings appeared during deployment"

  printf '%s\n' "$backup" > "$STATE_FILE"
  chmod 600 "$STATE_FILE"
  mutated=0
  trap - ERR
  trap - EXIT
  rm -rf "$stage"

  echo
  echo "============================================================"
  echo " PASS — BRIMSTONE MEGA S4 v4 DEPLOYED"
  echo "============================================================"
  echo "Live DLL : $EXPECTED_NEW_DLL_HASH"
  echo "Handler  : $HANDLER_LIVE"
  echo "UI       : v4 overlay installed on source + served bundles"
  echo "Mega rows: 0"
  echo "Old maps : 0"
  echo "Backup   : $backup"
  echo "============================================================"
}

status_v4(){
  docker inspect "$C" >/dev/null 2>&1 || fail "CommunityServer missing"
  local h handler="missing" ui="unknown"
  h="$(chash)"
  if docker exec "$C" test -f "$HANDLER_LIVE"; then handler="present"; fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]]; then
    discover_ui
    local total=0 good=0 f
    for f in "${SOURCES[@]}" "${BUNDLES[@]}"; do total=$((total+1)); [[ "$(docker exec "$C" grep -aFc "$V4_MARKER" "$f")" -eq 1 ]] && good=$((good+1)); done
    ui="$good/$total v4-marked"
  fi
  echo "Live DLL : $h"
  case "$h" in "$EXPECTED_NEW_DLL_HASH") echo "State    : BRIMSTONE MEGA S4 v4";; "$EXPECTED_OLD_DLL_HASH") echo "State    : PROVIDER CONTRACT v3 BACKEND";; *) echo "State    : UNKNOWN DLL HASH";; esac
  echo "Handler  : $handler"
  echo "UI       : $ui"
  echo "Mega rows: $(mega_rows)"
  echo "Old maps : $(old_maps)"
  [[ -s "$STATE_FILE" ]] && echo "Backup   : $(cat "$STATE_FILE")" || echo "Backup   : no v4 state file"
}

rollback_v4(){
  [[ -s "$STATE_FILE" ]] || fail "no Brimstone v4 state file"
  local backup handler_existed rows
  backup="$(cat "$STATE_FILE")"
  test -d "$backup" || fail "backup directory missing: $backup"
  test -s "$backup/ASC.Files.Thirdparty.dll" || fail "backup DLL missing"
  test -s "$backup/files.tar.gz" || fail "backup UI archive missing"
  [[ "$(sha256sum "$backup/ASC.Files.Thirdparty.dll" | awk '{print $1}')" == "$EXPECTED_OLD_DLL_HASH" ]] || fail "backup DLL hash mismatch"
  rows="$(mega_rows)"; [[ "$rows" == "0" ]] || fail "MegaS4 rows exist ($rows); refusing rollback across provider contracts"
  [[ "$(chash)" == "$EXPECTED_NEW_DLL_HASH" ]] || fail "live DLL is not Brimstone v4"
  handler_existed="$(awk -F= '$1=="handler_existed"{print $2}' "$backup/MANIFEST")"
  [[ "$handler_existed" == "0" || "$handler_existed" == "1" ]] || fail "invalid handler backup state"
  restore_backup "$backup" "$handler_existed"
  [[ "$(chash)" == "$EXPECTED_OLD_DLL_HASH" ]] || fail "rollback DLL hash mismatch"
  rm -f "$STATE_FILE"
  echo "PASS — BRIMSTONE MEGA S4 v4 rolled back completely"
}

case "$MODE" in
  preflight) preflight ;;
  install) install_v4 ;;
  status) status_v4 ;;
  rollback) rollback_v4 ;;
  *) echo "Usage: $0 {preflight|install|status|rollback}" >&2; exit 2 ;;
esac
