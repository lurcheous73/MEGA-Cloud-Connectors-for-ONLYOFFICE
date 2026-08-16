#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-status}"
C="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
LIVE_ROOT="/var/www/onlyoffice/WebStudio"
BUNDLE_DIR="$LIVE_ROOT/App_Data/static/bundle/files/javascript"
MARKER="MEGA S4 LIVE EXTENSION v1"
STATE_DIR="/var/lib/mega-cloud-connectors-for-onlyoffice/mega-s4"
LATEST_FILE="$STATE_DIR/latest-backup"
EXPECTED_MEGA_DLL="98df3165b21b2011899f17d773f3695437706d01fdcc8e3899303462157acf01"
LIVE_DLL="$LIVE_ROOT/bin/ASC.Files.Thirdparty.dll"

fail() { echo "FAIL: $*" >&2; exit 1; }

find_bundle() {
    mapfile -t bundles < <(docker exec "$C" sh -lc "find '$BUNDLE_DIR' -maxdepth 1 -type f -name 'files-*.js' -print | sort" | tr -d '\r')
    [ "${#bundles[@]}" -eq 1 ] || fail "expected exactly one Files JS bundle, found ${#bundles[@]}"
    printf '%s\n' "${bundles[0]}"
}

require_live_install() {
    docker inspect "$C" >/dev/null 2>&1 || fail "container $C not found"
    [ "$(docker inspect -f '{{.State.Running}}' "$C")" = "true" ] || fail "$C is not running"
    [ "$(docker exec "$C" sha256sum "$LIVE_DLL" | awk '{print $1}')" = "$EXPECTED_MEGA_DLL" ] || fail "MEGA S4 backend DLL is not installed"
}

same_payload() {
    local bundle="$1" gz="$2"
    docker exec "$C" bash -lc "set -o pipefail; gzip -dc '$gz' | cmp - '$bundle' >/dev/null"
}

status_mode() {
    require_live_install
    local bundle gz
    bundle="$(find_bundle)"
    gz="$bundle.gz"

    echo "Bundle: $bundle"
    docker exec "$C" test -s "$gz" || { echo "Gzip: missing"; return 1; }
    echo "Plain SHA256: $(docker exec "$C" sha256sum "$bundle" | awk '{print $1}')"
    echo "Gzip SHA256 : $(docker exec "$C" sha256sum "$gz" | awk '{print $1}')"

    if same_payload "$bundle" "$gz"; then
        echo "Gzip payload: MATCHES current plain bundle"
        docker exec "$C" bash -lc "set -o pipefail; gzip -dc '$gz' | grep -aFq '$MARKER'" || fail "gzip payload matches but MEGA S4 marker is absent"
        echo "MEGA marker: present in gzip payload"
        return 0
    fi

    echo "Gzip payload: STALE / DOES NOT MATCH current plain bundle"
    return 2
}

backup_old_gzip() {
    local bundle="$1" gz="$2" backup="$3"
    mkdir -p "$backup"

    if [ -s "$backup/files-bundle.js.gz" ]; then
        (cd "$backup" && sha256sum -c SHA256SUMS-GZIP >/dev/null) || fail "existing gzip backup checksum failed"
        echo "Existing gzip rollback copy already validated: $backup/files-bundle.js.gz"
        return 0
    fi

    docker exec "$C" test -s "$gz" || fail "stock/pre-existing gzip asset missing: $gz"
    docker cp "$C:$gz" "$backup/files-bundle.js.gz"
    docker exec "$C" stat -c '%u:%g %a' "$gz" > "$backup/bundle-gzip.meta"
    (cd "$backup" && sha256sum files-bundle.js.gz > SHA256SUMS-GZIP && sha256sum -c SHA256SUMS-GZIP)
    echo "Saved gzip rollback copy: $backup/files-bundle.js.gz"
}

repair_mode() {
    require_live_install
    [ -s "$LATEST_FILE" ] || fail "installer rollback state missing: $LATEST_FILE"

    local bundle gz backup
    bundle="$(find_bundle)"
    gz="$bundle.gz"
    backup="$(cat "$LATEST_FILE")"
    [ -d "$backup" ] || fail "installer backup directory missing: $backup"

    docker exec "$C" grep -aFq "$MARKER" "$bundle" || fail "plain Files bundle does not contain MEGA S4 marker"
    backup_old_gzip "$bundle" "$gz" "$backup"

    echo "Regenerating precompressed asset from the live patched bundle..."
    docker exec "$C" bash -lc "
        set -euo pipefail
        BUNDLE='$bundle'
        GZ='$gz'
        TMP=\"\${GZ}.megas4-new\"
        rm -f \"\$TMP\"
        gzip -9 -c \"\$BUNDLE\" > \"\$TMP\"
        gzip -t \"\$TMP\"
        gzip -dc \"\$TMP\" | cmp - \"\$BUNDLE\"
        cat \"\$TMP\" > \"\$GZ\"
        rm -f \"\$TMP\"
        gzip -t \"\$GZ\"
        gzip -dc \"\$GZ\" | cmp - \"\$BUNDLE\"
        gzip -dc \"\$GZ\" | grep -aFq '$MARKER'
    "

    if docker exec "$C" command -v nginx >/dev/null 2>&1; then
        docker exec "$C" nginx -t >/dev/null
        docker exec "$C" nginx -s reload
        echo "Nginx configuration validated and reloaded."
    fi

    echo
    status_mode
    echo
    echo "PASS — precompressed Files bundle regenerated and validated."
    echo "Rollback gzip copy: $backup/files-bundle.js.gz"
}

rollback_gzip_mode() {
    require_live_install
    [ -s "$LATEST_FILE" ] || fail "installer rollback state missing: $LATEST_FILE"

    local bundle gz backup owner mode
    bundle="$(find_bundle)"
    gz="$bundle.gz"
    backup="$(cat "$LATEST_FILE")"
    [ -s "$backup/files-bundle.js.gz" ] || fail "gzip rollback copy missing"
    [ -s "$backup/bundle-gzip.meta" ] || fail "gzip metadata backup missing"
    (cd "$backup" && sha256sum -c SHA256SUMS-GZIP) || fail "gzip rollback checksum failed"

    read -r owner mode < "$backup/bundle-gzip.meta"
    docker cp "$backup/files-bundle.js.gz" "$C:$gz"
    docker exec "$C" chown "$owner" "$gz"
    docker exec "$C" chmod "$mode" "$gz"
    docker exec "$C" gzip -t "$gz"

    if docker exec "$C" command -v nginx >/dev/null 2>&1; then
        docker exec "$C" nginx -t >/dev/null
        docker exec "$C" nginx -s reload
    fi

    echo "PASS — original precompressed Files bundle restored."
}

case "$MODE" in
    status) status_mode ;;
    repair) repair_mode ;;
    rollback-gzip) rollback_gzip_mode ;;
    *) echo "Usage: $0 {status|repair|rollback-gzip}" >&2; exit 2 ;;
esac
