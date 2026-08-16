#!/usr/bin/env bash
set -Eeuo pipefail

# BRIMSTONE CUSTOM CODE — UI-only fix for the v4 MutationObserver feedback loop.
REPO="${REPO:-/opt/mega-cloud-connectors-for-onlyoffice}"
C="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
DB="${MYSQL_CONTAINER:-onlyoffice-mysql-server}"
LIVE_DLL="/var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll"
HANDLER="/var/www/onlyoffice/WebStudio/Products/Files/HttpHandlers/brimstone-megas4.ashx"
FIXED="$REPO/src/mega-s4/communityserver-12.8/ui/brimstone-mega-s4-v4.1-overlay.js"
EXPECTED_DLL="a5d6698434ef9a18909aa6a2b42657472d832396a918ae648bee2c63255133d2"
V2_MARKER="MEGA S4 LIVE EXTENSION v2"
OLD_MARKER="BRIMSTONE MEGA S4 LIVE EXTENSION v4"
NEW_MARKER="BRIMSTONE MEGA S4 LIVE EXTENSION v4.1"
BACKUP_ROOT="/var/backups/mega-cloud-connectors-for-onlyoffice"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BACKUP_ROOT/brimstone-mega-s4-v4.1-ui-loopfix-$STAMP"
STAGE="$(mktemp -d /tmp/brimstone-mega-s4-v41.XXXXXX)"
MUTATED=0

fail(){ echo "FAIL: $*" >&2; exit 1; }
cleanup(){ rm -rf "$STAGE"; }
trap cleanup EXIT

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

restore_on_error(){
  local rc=$?
  trap - ERR
  set +e
  if [[ "$MUTATED" == "1" && -s "$BACKUP/files.tar.gz" ]]; then
    echo "ERROR after UI mutation — restoring v4 UI backup..." >&2
    docker cp "$BACKUP/files.tar.gz" "$C:/tmp/brimstone-v41-rollback.tar.gz" >/dev/null 2>&1
    docker exec "$C" tar -C / -xzf /tmp/brimstone-v41-rollback.tar.gz >/dev/null 2>&1
    docker exec "$C" rm -f /tmp/brimstone-v41-rollback.tar.gz >/dev/null 2>&1
    docker restart "$C" >/dev/null 2>&1
    sleep 8
    echo "Rollback attempted from $BACKUP/files.tar.gz" >&2
  fi
  exit "$rc"
}
trap restore_on_error ERR

echo "============================================================"
echo " BRIMSTONE MEGA S4 v4.1 — UI LOOP FIX"
echo "============================================================"

test -d "$REPO/.git" || fail "repository missing: $REPO"
[[ -z "$(git -C "$REPO" status --porcelain)" ]] || fail "repository worktree is not clean"
test -s "$FIXED" || fail "v4.1 overlay missing: $FIXED"
[[ "$(grep -cF "$NEW_MARKER" "$FIXED")" -eq 1 ]] || fail "v4.1 source marker invalid"
grep -Fq 'rowsAlreadyOrdered' "$FIXED" || fail "idempotent row-order guard missing"
grep -Fq 'observer = new MutationObserver(queueNormalise)' "$FIXED" || fail "debounced observer guard missing"
grep -Fq 'data-brimstone-megas4-layout", "v4.1"' "$FIXED" || fail "v4.1 form marker missing"

docker inspect "$C" >/dev/null 2>&1 || fail "CommunityServer missing"
docker inspect "$DB" >/dev/null 2>&1 || fail "MySQL missing"
[[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer is not running"
[[ "$(docker inspect -f '{{.State.Running}}' "$DB")" == "true" ]] || fail "MySQL is not running"
[[ "$(docker exec "$C" sha256sum "$LIVE_DLL" | awk '{print $1}')" == "$EXPECTED_DLL" ]] || fail "unexpected live DLL"
docker exec "$C" test -s "$HANDLER" || fail "Brimstone handler missing"
[[ "$(mega_rows)" == "0" ]] || fail "MegaS4 provider rows exist; refusing UI hotfix"
[[ "$(old_maps)" == "0" ]] || fail "old MEGA mappings exist; refusing UI hotfix"
echo "PASS: backend, handler and DB state are expected"

mapfile -t SOURCES < <(docker exec "$C" sh -lc "find /var/www/onlyoffice -path '*/Products/Files/Controls/ThirdParty/thirdparty.js' -type f -print | sort" | tr -d '\r')
mapfile -t BUNDLES < <(docker exec "$C" sh -lc "find /var/www/onlyoffice -path '*/App_Data/static/bundle/files/javascript/files-*.js' -type f -print | sort; find /var/www/onlyoffice/Data/bundle/files/javascript -maxdepth 1 -type f -name 'files-*.js' -print | sort" | tr -d '\r')
[[ "${#SOURCES[@]}" -ge 1 ]] || fail "no Files ThirdParty source JS found"
[[ "${#BUNDLES[@]}" -ge 2 ]] || fail "expected Files bundle copies"

FILES=()
for f in "${SOURCES[@]}" "${BUNDLES[@]}"; do
  [[ "$(docker exec "$C" grep -aFc "$V2_MARKER" "$f")" -eq 1 ]] || fail "v2 marker missing/duplicate: $f"
  [[ "$(docker exec "$C" grep -aFc "$NEW_MARKER" "$f")" -eq 0 ]] || fail "v4.1 already present: $f"
  # OLD_MARKER also prefixes v4.1, so v4.1 absence is checked first.
  [[ "$(docker exec "$C" grep -aFc "$OLD_MARKER" "$f")" -eq 1 ]] || fail "v4 marker missing/duplicate: $f"
  FILES+=("$f")
  if docker exec "$C" test -f "$f.gz"; then
    docker exec "$C" gzip -t "$f.gz" || fail "bad gzip before hotfix: $f.gz"
    FILES+=("$f.gz")
  fi
done

echo "PASS: current v4 UI found in ${#SOURCES[@]} source and ${#BUNDLES[@]} bundle copies"

mkdir -p "$BACKUP"
chmod 700 "$BACKUP"
printf '%s\n' "${FILES[@]}" > "$BACKUP/files.list"
REL=(); for f in "${FILES[@]}"; do REL+=("${f#/}"); done
docker exec "$C" tar -C / -czf /tmp/brimstone-v41-backup.tar.gz "${REL[@]}"
docker cp "$C:/tmp/brimstone-v41-backup.tar.gz" "$BACKUP/files.tar.gz" >/dev/null
docker exec "$C" rm -f /tmp/brimstone-v41-backup.tar.gz
tar -tzf "$BACKUP/files.tar.gz" >/dev/null
sha256sum "$BACKUP/files.tar.gz" > "$BACKUP/SHA256SUMS"
(cd "$BACKUP" && sha256sum -c SHA256SUMS)
echo "PASS: UI backup created at $BACKUP"

for f in "${SOURCES[@]}" "${BUNDLES[@]}"; do
  mkdir -p "$STAGE$(dirname "$f")"
  docker cp "$C:$f" "$STAGE$f" >/dev/null
  python3 - "$STAGE$f" "$FIXED" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
fixed = pathlib.Path(sys.argv[2]).read_bytes()
data = path.read_bytes()
old = b"/* BRIMSTONE MEGA S4 LIVE EXTENSION v4\n"
new = b"/* BRIMSTONE MEGA S4 LIVE EXTENSION v4.1\n"
if data.count(new) != 0:
    raise SystemExit("FAIL - v4.1 marker already present in staged file")
if data.count(old) != 1:
    raise SystemExit("FAIL - exact v4 tail marker count is not 1")
pos = data.index(old)
prefix = data[:pos].rstrip(b"\r\n") + b"\n\n"
path.write_bytes(prefix + fixed.rstrip(b"\r\n") + b"\n")
PY
  [[ "$(grep -aFc "$NEW_MARKER" "$STAGE$f")" -eq 1 ]] || fail "staged v4.1 marker failed: $f"
  [[ "$(grep -aFc "$V2_MARKER" "$STAGE$f")" -eq 1 ]] || fail "staged v2 marker changed: $f"
  if docker exec "$C" test -f "$f.gz"; then
    gzip -c "$STAGE$f" > "$STAGE$f.gz"
    gzip -t "$STAGE$f.gz"
  fi
done

echo "PASS: all replacement copies built off-line"

MUTATED=1
for f in "${SOURCES[@]}" "${BUNDLES[@]}"; do
  docker cp "$STAGE$f" "$C:$f" >/dev/null
  if [[ -s "$STAGE$f.gz" ]]; then docker cp "$STAGE$f.gz" "$C:$f.gz" >/dev/null; fi
done

docker restart "$C" >/dev/null
sleep 8
[[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer failed to return"
[[ "$(docker exec "$C" sha256sum "$LIVE_DLL" | awk '{print $1}')" == "$EXPECTED_DLL" ]] || fail "backend DLL changed unexpectedly"
docker exec "$C" test -s "$HANDLER" || fail "handler disappeared"
[[ "$(mega_rows)" == "0" ]] || fail "DB changed during UI hotfix"
[[ "$(old_maps)" == "0" ]] || fail "old mappings appeared during UI hotfix"

for f in "${SOURCES[@]}" "${BUNDLES[@]}"; do
  [[ "$(docker exec "$C" grep -aFc "$NEW_MARKER" "$f")" -eq 1 ]] || fail "v4.1 marker missing after restart: $f"
  if docker exec "$C" test -f "$f.gz"; then
    docker exec "$C" sh -lc "gzip -t '$f.gz' && gzip -dc '$f.gz' | cmp - '$f'" || fail "gzip mismatch: $f.gz"
  fi
done

MUTATED=0
trap - ERR

echo "============================================================"
echo " PASS — BRIMSTONE MEGA S4 v4.1 UI LOOP FIX INSTALLED"
echo "============================================================"
echo "Backend : unchanged ($EXPECTED_DLL)"
echo "Handler : unchanged"
echo "Database: Mega rows 0 / old maps 0"
echo "UI      : v4.1 in $(( ${#SOURCES[@]} + ${#BUNDLES[@]} )) JS copies"
echo "Backup  : $BACKUP"
echo "============================================================"
