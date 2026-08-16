#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-status}"
C="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
PORTAL_HOST="${MEGA_S4_PORTAL_HOST:-work.brimstonecottage.uk}"
PORTAL_VER="${MEGA_S4_PORTAL_VER:-12.8.0.699}"

NAME="files-6zQSAGbsjVfnA1EyaHmOMQ2.js"
MARKER="MEGA S4 LIVE EXTENSION v1"

SOURCE="/var/www/onlyoffice/WebStudio/App_Data/static/bundle/files/javascript/$NAME"
SOURCE_GZ="$SOURCE.gz"
TARGET="/var/www/onlyoffice/Data/bundle/files/javascript/$NAME"
TARGET_GZ="$TARGET.gz"
LIVE_DLL="/var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll"

EXPECTED_MEGA_DLL="98df3165b21b2011899f17d773f3695437706d01fdcc8e3899303462157acf01"
EXPECTED_PATCHED_BUNDLE="ddb7939dc6af0bc2384285c9535fa0580466cdb1272a5d6b6864be9e1db8b273"
EXPECTED_STOCK_DISCBUNDLE="1077a3c78a388d1c2a88fddb49d19af4019cebd9a86c7c25e7c82d1e9f555714"

STATE_DIR="/var/lib/mega-cloud-connectors-for-onlyoffice/mega-s4"
LATEST_FILE="$STATE_DIR/latest-backup"

fail() { echo "FAIL: $*" >&2; exit 1; }
chash() { docker exec "$C" sha256sum "$1" | awk '{print $1}'; }

require_live() {
    docker inspect "$C" >/dev/null 2>&1 || fail "container $C not found"
    [ "$(docker inspect -f '{{.State.Running}}' "$C")" = "true" ] || fail "$C is not running"
    [ "$(chash "$LIVE_DLL")" = "$EXPECTED_MEGA_DLL" ] || fail "MEGA S4 backend DLL is not installed"
    docker exec "$C" test -s "$SOURCE" || fail "patched source bundle missing: $SOURCE"
    docker exec "$C" test -s "$SOURCE_GZ" || fail "patched source gzip missing: $SOURCE_GZ"
    docker exec "$C" test -s "$TARGET" || fail "served discbundle missing: $TARGET"
    docker exec "$C" test -s "$TARGET_GZ" || fail "served discbundle gzip missing: $TARGET_GZ"
    [ "$(chash "$SOURCE")" = "$EXPECTED_PATCHED_BUNDLE" ] || fail "patched source bundle hash is not the validated MEGA build"
    docker exec "$C" grep -aFq "$MARKER" "$SOURCE" || fail "patched source bundle lacks MEGA marker"
    docker exec "$C" bash -lc "set -o pipefail; gzip -dc '$SOURCE_GZ' | cmp - '$SOURCE' >/dev/null" || fail "patched source gzip does not match source bundle"
}

public_check() {
    local tmp url code
    tmp="$(mktemp /tmp/megas4-discbundle-http.XXXXXX.js)"
    url="https://${PORTAL_HOST}/discbundle/files/_t/${NAME}?ver=${PORTAL_VER}&megas4=$(date +%s%N)"
    code="$(curl -sk --compressed -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' -o "$tmp" -w '%{http_code}' "$url")"
    echo "Public URL: $url"
    echo "HTTP: $code"
    echo "Bytes: $(wc -c < "$tmp")"
    echo "SHA256: $(sha256sum "$tmp" | awk '{print $1}')"
    [ "$code" = "200" ] || { rm -f "$tmp"; fail "public discbundle returned HTTP $code"; }
    grep -aFq "$MARKER" "$tmp" || { rm -f "$tmp"; fail "public /discbundle response still lacks MEGA marker"; }
    [ "$(sha256sum "$tmp" | awk '{print $1}')" = "$EXPECTED_PATCHED_BUNDLE" ] || { rm -f "$tmp"; fail "public /discbundle payload does not equal validated patched bundle"; }
    rm -f "$tmp"
    echo "PASS: public /discbundle serves validated MEGA bundle"
}

status_mode() {
    require_live
    echo "Source bundle : $(chash "$SOURCE")"
    echo "Served bundle : $(chash "$TARGET")"
    echo "Stock baseline: $EXPECTED_STOCK_DISCBUNDLE"

    if docker exec "$C" grep -aFq "$MARKER" "$TARGET"; then
        echo "Served MEGA marker: YES"
    else
        echo "Served MEGA marker: NO"
    fi

    if docker exec "$C" bash -lc "set -o pipefail; gzip -dc '$TARGET_GZ' | cmp - '$TARGET' >/dev/null"; then
        echo "Served gzip: MATCHES served plain bundle"
    else
        echo "Served gzip: STALE / MISMATCH"
    fi

    if [ "$(chash "$TARGET")" = "$EXPECTED_PATCHED_BUNDLE" ]; then
        public_check
        echo "PASS — discbundle layer is MEGA S4 current"
        return 0
    fi

    echo "DISCBUNDLE REPAIR REQUIRED"
    return 2
}

backup_target() {
    local backup="$1"
    mkdir -p "$backup"

    if [ -s "$backup/discbundle-files.js" ] || [ -s "$backup/discbundle-files.js.gz" ]; then
        [ -s "$backup/SHA256SUMS-DISCBUNDLE" ] || fail "partial existing discbundle backup in $backup"
        (cd "$backup" && sha256sum -c SHA256SUMS-DISCBUNDLE) || fail "existing discbundle backup checksum failed"
        echo "Existing discbundle rollback copy validated."
        return 0
    fi

    docker cp "$C:$TARGET" "$backup/discbundle-files.js"
    docker cp "$C:$TARGET_GZ" "$backup/discbundle-files.js.gz"
    docker exec "$C" stat -c '%u:%g %a' "$TARGET" > "$backup/discbundle-js.meta"
    docker exec "$C" stat -c '%u:%g %a' "$TARGET_GZ" > "$backup/discbundle-gzip.meta"

    (cd "$backup" && sha256sum discbundle-files.js discbundle-files.js.gz > SHA256SUMS-DISCBUNDLE && sha256sum -c SHA256SUMS-DISCBUNDLE)
    echo "Saved rollback copies in $backup"
}

repair_mode() {
    require_live
    [ -s "$LATEST_FILE" ] || fail "installer rollback state missing: $LATEST_FILE"
    local backup current
    backup="$(cat "$LATEST_FILE")"
    [ -d "$backup" ] || fail "installer backup directory missing: $backup"

    current="$(chash "$TARGET")"
    if [ "$current" = "$EXPECTED_PATCHED_BUNDLE" ]; then
        echo "Served discbundle already matches patched source."
        status_mode
        return 0
    fi
    [ "$current" = "$EXPECTED_STOCK_DISCBUNDLE" ] || fail "served discbundle is neither validated stock nor validated patched copy: $current"

    backup_target "$backup"

    local tmp
    tmp="$(mktemp -d /tmp/megas4-discbundle.XXXXXX)"
    trap 'rm -rf "$tmp"' RETURN

    docker cp "$C:$SOURCE" "$tmp/files.js" >/dev/null
    docker cp "$C:$SOURCE_GZ" "$tmp/files.js.gz" >/dev/null
    [ "$(sha256sum "$tmp/files.js" | awk '{print $1}')" = "$EXPECTED_PATCHED_BUNDLE" ] || fail "staged patched bundle hash mismatch"
    gzip -t "$tmp/files.js.gz"
    gzip -dc "$tmp/files.js.gz" | cmp - "$tmp/files.js" || fail "staged gzip payload mismatch"

    docker cp "$tmp/files.js" "$C:$TARGET"
    docker cp "$tmp/files.js.gz" "$C:$TARGET_GZ"

    local owner mode
    read -r owner mode < "$backup/discbundle-js.meta"
    docker exec "$C" chown "$owner" "$TARGET"
    docker exec "$C" chmod "$mode" "$TARGET"
    read -r owner mode < "$backup/discbundle-gzip.meta"
    docker exec "$C" chown "$owner" "$TARGET_GZ"
    docker exec "$C" chmod "$mode" "$TARGET_GZ"

    [ "$(chash "$TARGET")" = "$EXPECTED_PATCHED_BUNDLE" ] || fail "served bundle post-copy hash mismatch"
    docker exec "$C" grep -aFq "$MARKER" "$TARGET" || fail "served bundle post-copy marker missing"
    docker exec "$C" gzip -t "$TARGET_GZ"
    docker exec "$C" bash -lc "set -o pipefail; gzip -dc '$TARGET_GZ' | cmp - '$TARGET' >/dev/null" || fail "served gzip post-copy mismatch"

    public_check

    echo
    echo "PASS — actual /discbundle cache repaired and validated."
    echo "Rollback copies: $backup/discbundle-files.js{,.gz}"
}

rollback_mode() {
    require_live
    [ -s "$LATEST_FILE" ] || fail "installer rollback state missing: $LATEST_FILE"
    local backup owner mode
    backup="$(cat "$LATEST_FILE")"
    [ -s "$backup/discbundle-files.js" ] || fail "discbundle JS rollback copy missing"
    [ -s "$backup/discbundle-files.js.gz" ] || fail "discbundle gzip rollback copy missing"
    [ -s "$backup/SHA256SUMS-DISCBUNDLE" ] || fail "discbundle checksum file missing"
    (cd "$backup" && sha256sum -c SHA256SUMS-DISCBUNDLE) || fail "discbundle rollback checksum failed"

    docker cp "$backup/discbundle-files.js" "$C:$TARGET"
    docker cp "$backup/discbundle-files.js.gz" "$C:$TARGET_GZ"

    read -r owner mode < "$backup/discbundle-js.meta"
    docker exec "$C" chown "$owner" "$TARGET"
    docker exec "$C" chmod "$mode" "$TARGET"
    read -r owner mode < "$backup/discbundle-gzip.meta"
    docker exec "$C" chown "$owner" "$TARGET_GZ"
    docker exec "$C" chmod "$mode" "$TARGET_GZ"

    [ "$(chash "$TARGET")" = "$EXPECTED_STOCK_DISCBUNDLE" ] || fail "discbundle rollback did not restore stock hash"
    docker exec "$C" gzip -t "$TARGET_GZ"
    docker exec "$C" bash -lc "set -o pipefail; gzip -dc '$TARGET_GZ' | cmp - '$TARGET' >/dev/null" || fail "rolled-back gzip does not match rolled-back JS"
    echo "PASS — served /discbundle layer restored to validated stock baseline."
}

case "$MODE" in
    status) status_mode ;;
    repair) repair_mode ;;
    rollback-discbundle) rollback_mode ;;
    *) echo "Usage: $0 {status|repair|rollback-discbundle}" >&2; exit 2 ;;
esac
