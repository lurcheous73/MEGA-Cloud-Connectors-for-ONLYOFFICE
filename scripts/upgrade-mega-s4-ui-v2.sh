#!/usr/bin/env bash
set -Eeuo pipefail

C="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXTENSION="$REPO_ROOT/src/mega-s4/communityserver-12.8/ui/mega-s4-thirdparty-extension.js"

V1="MEGA S4 LIVE EXTENSION v1"
V2="MEGA S4 LIVE EXTENSION v2"
EXPECTED_MEGA_DLL="98df3165b21b2011899f17d773f3695437706d01fdcc8e3899303462157acf01"
LIVE_DLL="/var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll"
BACKUP_ROOT="/var/backups/mega-cloud-connectors-for-onlyoffice"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BACKUP_ROOT/mega-s4-ui-v2-$TS"
REMOTE_TAR="/tmp/mega-s4-ui-v2-$TS.tar.gz"
REMOTE_EXT="/tmp/mega-s4-thirdparty-extension-v2.js"
MUTATED=0

fail() { echo "FAIL: $*" >&2; exit 1; }
chash() { docker exec "$C" sha256sum "$1" | awk '{print $1}'; }

restore_on_error() {
    local rc=$?
    trap - ERR
    if [ "$MUTATED" -eq 1 ] && [ -s "$BACKUP/files.tar.gz" ]; then
        echo "ERROR after mutation — restoring UI bundle backup..." >&2
        set +e
        docker cp "$BACKUP/files.tar.gz" "$C:$REMOTE_TAR" >/dev/null
        docker exec "$C" tar -C / -xzf "$REMOTE_TAR"
        docker exec "$C" rm -f "$REMOTE_TAR" "$REMOTE_EXT"
        docker restart "$C" >/dev/null
        set -e
        echo "Rollback attempted from $BACKUP/files.tar.gz" >&2
    fi
    exit "$rc"
}
trap restore_on_error ERR

[ -s "$EXTENSION" ] || fail "v2 extension missing: $EXTENSION"
[ "$(grep -cF "$V2" "$EXTENSION")" -eq 1 ] || fail "v2 extension marker invalid"

docker inspect "$C" >/dev/null 2>&1 || fail "container $C not found"
[ "$(docker inspect -f '{{.State.Running}}' "$C")" = "true" ] || fail "$C is not running"
[ "$(chash "$LIVE_DLL")" = "$EXPECTED_MEGA_DLL" ] || fail "validated MEGA S4 backend DLL is not installed"

mapfile -t SOURCES < <(docker exec "$C" sh -lc "find /var/www/onlyoffice -path '*/Products/Files/Controls/ThirdParty/thirdparty.js' -type f -print | sort" | tr -d '\r')
mapfile -t BUNDLES < <(docker exec "$C" sh -lc "find /var/www/onlyoffice -path '*/App_Data/static/bundle/files/javascript/files-*.js' -type f -print | sort; find /var/www/onlyoffice/Data/bundle/files/javascript -maxdepth 1 -type f -name 'files-*.js' -print | sort" | tr -d '\r')

[ "${#SOURCES[@]}" -ge 1 ] || fail "no ThirdParty source JS files found"
[ "${#BUNDLES[@]}" -ge 2 ] || fail "expected static and Data/bundle Files JS copies"

FILES=()
for f in "${SOURCES[@]}"; do
    [ "$(docker exec "$C" grep -aFc "$V1" "$f")" -eq 1 ] || fail "v1 marker missing/duplicate in $f"
    [ "$(docker exec "$C" grep -aFc "$V2" "$f")" -eq 0 ] || fail "v2 already present in $f"
    FILES+=("$f")
done

for f in "${BUNDLES[@]}"; do
    [ "$(docker exec "$C" grep -aFc "$V1" "$f")" -eq 1 ] || fail "v1 marker missing/duplicate in $f"
    [ "$(docker exec "$C" grep -aFc "$V2" "$f")" -eq 0 ] || fail "v2 already present in $f"
    FILES+=("$f")
    if docker exec "$C" test -f "$f.gz"; then
        docker exec "$C" gzip -t "$f.gz" || fail "bad gzip before upgrade: $f.gz"
        FILES+=("$f.gz")
    fi
done

mkdir -p "$BACKUP"
printf '%s\n' "${FILES[@]}" > "$BACKUP/files.list"
REL=()
for f in "${FILES[@]}"; do REL+=("${f#/}"); done

docker exec "$C" tar -C / -czf "$REMOTE_TAR" "${REL[@]}"
docker cp "$C:$REMOTE_TAR" "$BACKUP/files.tar.gz" >/dev/null
docker exec "$C" rm -f "$REMOTE_TAR"
sha256sum "$BACKUP/files.tar.gz" > "$BACKUP/SHA256SUMS"
sha256sum -c "$BACKUP/SHA256SUMS"

docker cp "$EXTENSION" "$C:$REMOTE_EXT" >/dev/null
MUTATED=1

for f in "${SOURCES[@]}"; do
    docker exec "$C" sh -lc "printf '\n\n' >> '$f'; cat '$REMOTE_EXT' >> '$f'"
    [ "$(docker exec "$C" grep -aFc "$V2" "$f")" -eq 1 ] || fail "v2 source marker validation failed: $f"
done

for f in "${BUNDLES[@]}"; do
    docker exec "$C" sh -lc "printf '\n\n' >> '$f'; cat '$REMOTE_EXT' >> '$f'"
    [ "$(docker exec "$C" grep -aFc "$V2" "$f")" -eq 1 ] || fail "v2 bundle marker validation failed: $f"
    if docker exec "$C" test -f "$f.gz"; then
        docker exec "$C" sh -lc "gzip -c '$f' > '$f.gz'; gzip -t '$f.gz'; gzip -dc '$f.gz' | cmp - '$f'"
    fi
done

docker exec "$C" rm -f "$REMOTE_EXT"
docker restart "$C" >/dev/null
sleep 8
[ "$(docker inspect -f '{{.State.Running}}' "$C")" = "true" ] || fail "CommunityServer did not return after v2 upgrade"

for f in "${SOURCES[@]}"; do
    [ "$(docker exec "$C" grep -aFc "$V2" "$f")" -eq 1 ] || fail "v2 source marker disappeared after restart: $f"
done
for f in "${BUNDLES[@]}"; do
    [ "$(docker exec "$C" grep -aFc "$V2" "$f")" -eq 1 ] || fail "v2 bundle marker disappeared after restart: $f"
    if docker exec "$C" test -f "$f.gz"; then
        docker exec "$C" sh -lc "gzip -t '$f.gz'; gzip -dc '$f.gz' | cmp - '$f'" || fail "gzip mismatch after restart: $f.gz"
    fi
done

MUTATED=0

echo "============================================================"
echo " PASS — MEGA S4 UI v2 INSTALLED AND VALIDATED"
echo "============================================================"
echo "Backup: $BACKUP"
echo "v2 retries until ONLYOFFICE ThirdParty and popup DOM exist."
