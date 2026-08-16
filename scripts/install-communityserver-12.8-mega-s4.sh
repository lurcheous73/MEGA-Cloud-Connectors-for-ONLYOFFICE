#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-status}"
C="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
IMAGE="onlyoffice/communityserver:12.8.0.1971"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXTENSION="$REPO_ROOT/src/mega-s4/communityserver-12.8/ui/mega-s4-thirdparty-extension.js"
CANDIDATE_DLL="${MEGA_S4_DLL:-/opt/communityserver-megas4-dev/web/studio/ASC.Web.Studio/bin/ASC.Files.Thirdparty.dll}"

LIVE_ROOT="/var/www/onlyoffice/WebStudio"
LIVE_DLL="$LIVE_ROOT/bin/ASC.Files.Thirdparty.dll"
LIVE_JS="$LIVE_ROOT/Products/Files/Controls/ThirdParty/thirdparty.js"
LIVE_XSL="$LIVE_ROOT/Products/Files/Templates/getthirdpartyitem.xsl"
LIVE_CONFIG="$LIVE_ROOT/web.appsettings.config"
BUNDLE_DIR="$LIVE_ROOT/App_Data/static/bundle/files/javascript"

EXPECTED_STOCK_DLL="0b7188ab9b94ee886814c96de7b678395596421cb46df6a9e541767aab01c89d"
EXPECTED_MEGA_DLL="98df3165b21b2011899f17d773f3695437706d01fdcc8e3899303462157acf01"
EXPECTED_STOCK_JS="c7bd83aaa28f02676e50b91a30d866e9366ec21565ee6a4f936649be65e50050"
EXPECTED_STOCK_XSL="b16b2e570a47693f1ac0f16112fd562d7ffd0eeef2f80a001e18ea36406fb646"
EXPECTED_ENABLE="box,dropboxv2,docusign,google,onedrive,sharepoint,nextcloud,owncloud,webdav,kdrive,yandex"
MARKER="MEGA S4 LIVE EXTENSION v1"

BACKUP_ROOT="/var/backups/mega-cloud-connectors-for-onlyoffice"
STATE_DIR="/var/lib/mega-cloud-connectors-for-onlyoffice/mega-s4"
LATEST_FILE="$STATE_DIR/latest-backup"

MUTATED=0
CURRENT_BACKUP=""

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

container_hash() {
    docker exec "$C" sha256sum "$1" | awk '{print $1}'
}

require_container() {
    docker inspect "$C" >/dev/null 2>&1 || fail "container $C not found"
    [ "$(docker inspect -f '{{.State.Running}}' "$C")" = "true" ] || fail "$C is not running"

    local expected_id actual_id
    expected_id="$(docker image inspect -f '{{.Id}}' "$IMAGE")"
    actual_id="$(docker inspect -f '{{.Image}}' "$C")"
    [ "$expected_id" = "$actual_id" ] || fail "CommunityServer image mismatch: expected $IMAGE"
}

find_bundle() {
    mapfile -t BUNDLES < <(docker exec "$C" sh -lc "find '$BUNDLE_DIR' -maxdepth 1 -type f -name 'files-*.js' -print | sort" | tr -d '\r')
    [ "${#BUNDLES[@]}" -eq 1 ] || fail "expected exactly one Files JS bundle, found ${#BUNDLES[@]}"
    printf '%s\n' "${BUNDLES[0]}"
}

verify_candidate_dll() {
    [ -s "$CANDIDATE_DLL" ] || fail "candidate DLL missing: $CANDIDATE_DLL"
    [ "$(sha256sum "$CANDIDATE_DLL" | awk '{print $1}')" = "$EXPECTED_MEGA_DLL" ] || fail "candidate DLL hash mismatch"

    local candidate_dir candidate_name
    candidate_dir="$(dirname "$CANDIDATE_DLL")"
    candidate_name="$(basename "$CANDIDATE_DLL")"

    docker run --rm \
        --entrypoint /bin/bash \
        -v "$candidate_dir:/candidate:ro" \
        "$IMAGE" \
        -lc "
            set -euo pipefail
            DLL=/candidate/$candidate_name
            TYPES=\"\$(monodis --typedef \"\$DLL\")\"
            for t in MegaS4Auth MegaS4DaoSelector MegaS4ProviderInfo MegaS4Storage MegaS4FileDao MegaS4FolderDao MegaS4SecurityDao MegaS4TagDao; do
                printf '%s\n' \"\$TYPES\" | grep -q \"\$t\" || { echo \"missing type: \$t\" >&2; exit 1; }
            done
            REFS=\"\$(monodis --assemblyref \"\$DLL\")\"
            printf '%s\n' \"\$REFS\" | grep -q 'Name=AWSSDK.S3' || exit 1
            printf '%s\n' \"\$REFS\" | grep -q 'Name=AWSSDK.Core' || exit 1
        " || fail "candidate CLR metadata validation failed"
}

verify_runtime_dependencies() {
    for f in AWSSDK.S3.dll AWSSDK.Core.dll; do
        docker exec "$C" test -s "$LIVE_ROOT/bin/$f" || fail "runtime dependency missing: $f"
        docker exec "$C" monodis --assembly "$LIVE_ROOT/bin/$f" 2>/dev/null | grep -q '^Version:[[:space:]]*4\.0\.0\.0' \
            || fail "$f is not assembly version 4.0.0.0"
    done
}

verify_stock_inputs() {
    [ "$(container_hash "$LIVE_DLL")" = "$EXPECTED_STOCK_DLL" ] || fail "live Thirdparty DLL is not the validated stock baseline"
    [ "$(container_hash "$LIVE_JS")" = "$EXPECTED_STOCK_JS" ] || fail "live thirdparty.js is not the validated stock baseline"
    [ "$(container_hash "$LIVE_XSL")" = "$EXPECTED_STOCK_XSL" ] || fail "live getthirdpartyitem.xsl is not the validated stock baseline"

    local enable_line
    enable_line="$(docker exec "$C" grep -F 'key="files.thirdparty.enable"' "$LIVE_CONFIG" || true)"
    [ "$(printf '%s\n' "$enable_line" | grep -c .)" -eq 1 ] || fail "files.thirdparty.enable key not found exactly once"
    printf '%s\n' "$enable_line" | grep -Fq "value=\"$EXPECTED_ENABLE\"" \
        || fail "files.thirdparty.enable differs from validated baseline"

    local bundle
    bundle="$(find_bundle)"
    docker exec "$C" grep -aFq 'thirdPartyList' "$bundle" || fail "Files bundle missing thirdPartyList marker"
    docker exec "$C" grep -aFq 'saveThirdPartyAccount' "$bundle" || fail "Files bundle missing saveThirdPartyAccount marker"
    docker exec "$C" grep -aFq 'add-account-button' "$bundle" || fail "Files bundle missing add-account-button marker"
    if docker exec "$C" grep -aFq "$MARKER" "$bundle"; then
        fail "MEGA S4 extension marker already present in Files bundle"
    fi
}

capture_meta() {
    local remote="$1" out="$2"
    docker exec "$C" stat -c '%u:%g %a' "$remote" > "$out"
}

restore_meta() {
    local remote="$1" meta="$2"
    local owner mode
    read -r owner mode < "$meta"
    docker exec "$C" chown "$owner" "$remote"
    docker exec "$C" chmod "$mode" "$remote"
}

create_backup() {
    local bundle ts
    bundle="$(find_bundle)"
    ts="$(date +%Y%m%d-%H%M%S)"
    CURRENT_BACKUP="$BACKUP_ROOT/mega-s4-$ts"
    mkdir -p "$CURRENT_BACKUP"

    printf '%s\n' "$bundle" > "$CURRENT_BACKUP/bundle.path"

    docker cp "$C:$LIVE_DLL" "$CURRENT_BACKUP/ASC.Files.Thirdparty.dll"
    docker cp "$C:$LIVE_JS" "$CURRENT_BACKUP/thirdparty.js"
    docker cp "$C:$LIVE_XSL" "$CURRENT_BACKUP/getthirdpartyitem.xsl"
    docker cp "$C:$LIVE_CONFIG" "$CURRENT_BACKUP/web.appsettings.config"
    docker cp "$C:$bundle" "$CURRENT_BACKUP/files-bundle.js"

    capture_meta "$LIVE_DLL" "$CURRENT_BACKUP/dll.meta"
    capture_meta "$LIVE_JS" "$CURRENT_BACKUP/js.meta"
    capture_meta "$LIVE_XSL" "$CURRENT_BACKUP/xsl.meta"
    capture_meta "$LIVE_CONFIG" "$CURRENT_BACKUP/config.meta"
    capture_meta "$bundle" "$CURRENT_BACKUP/bundle.meta"

    (cd "$CURRENT_BACKUP" && sha256sum \
        ASC.Files.Thirdparty.dll thirdparty.js getthirdpartyitem.xsl web.appsettings.config files-bundle.js \
        > SHA256SUMS && sha256sum -c SHA256SUMS)

    mkdir -p "$STATE_DIR"
}

rollback_from_backup() {
    local b="$1" bundle
    [ -d "$b" ] || fail "backup directory missing: $b"
    (cd "$b" && sha256sum -c SHA256SUMS) || fail "backup checksum verification failed"
    bundle="$(cat "$b/bundle.path")"

    docker cp "$b/ASC.Files.Thirdparty.dll" "$C:$LIVE_DLL"
    docker cp "$b/thirdparty.js" "$C:$LIVE_JS"
    docker cp "$b/getthirdpartyitem.xsl" "$C:$LIVE_XSL"
    docker cp "$b/web.appsettings.config" "$C:$LIVE_CONFIG"
    docker cp "$b/files-bundle.js" "$C:$bundle"

    restore_meta "$LIVE_DLL" "$b/dll.meta"
    restore_meta "$LIVE_JS" "$b/js.meta"
    restore_meta "$LIVE_XSL" "$b/xsl.meta"
    restore_meta "$LIVE_CONFIG" "$b/config.meta"
    restore_meta "$bundle" "$b/bundle.meta"

    docker restart "$C" >/dev/null
    sleep 5
    [ "$(docker inspect -f '{{.State.Running}}' "$C")" = "true" ] || fail "container did not return after rollback"
}

on_error() {
    local rc=$?
    trap - ERR
    if [ "$MUTATED" -eq 1 ] && [ -n "$CURRENT_BACKUP" ] && [ -d "$CURRENT_BACKUP" ]; then
        echo
        echo "ERROR after live mutation — restoring backup automatically..." >&2
        set +e
        rollback_from_backup "$CURRENT_BACKUP"
        local rr=$?
        set -e
        if [ "$rr" -eq 0 ]; then
            echo "Automatic rollback completed." >&2
        else
            echo "WARNING: automatic rollback encountered an error; backup is $CURRENT_BACKUP" >&2
        fi
    fi
    exit "$rc"
}
trap on_error ERR

status() {
    require_container
    local dll_hash bundle
    dll_hash="$(container_hash "$LIVE_DLL")"
    bundle="$(find_bundle)"

    echo "CommunityServer: $IMAGE"
    echo "Thirdparty DLL: $dll_hash"

    if [ "$dll_hash" = "$EXPECTED_MEGA_DLL" ]; then
        echo "Backend: MEGA S4 DLL installed"
    elif [ "$dll_hash" = "$EXPECTED_STOCK_DLL" ]; then
        echo "Backend: stock DLL"
    else
        echo "Backend: UNKNOWN DLL"
    fi

    if docker exec "$C" grep -aFq "$MARKER" "$bundle"; then
        echo "UI bundle: MEGA S4 extension installed"
    else
        echo "UI bundle: stock/no MEGA S4 extension"
    fi

    if docker exec "$C" grep -F 'key="files.thirdparty.enable"' "$LIVE_CONFIG" | grep -Fq 'megas4'; then
        echo "Config: megas4 enabled"
    else
        echo "Config: megas4 not enabled"
    fi
}

install_mode() {
    require_container
    verify_candidate_dll
    verify_runtime_dependencies

    if [ "$(container_hash "$LIVE_DLL")" = "$EXPECTED_MEGA_DLL" ]; then
        echo "MEGA S4 backend already installed; refusing a second install pass."
        status
        return 0
    fi

    verify_stock_inputs
    [ -s "$EXTENSION" ] || fail "UI extension missing: $EXTENSION"
    grep -Fq "$MARKER" "$EXTENSION" || fail "UI extension marker missing"

    echo "Validated stock baseline and candidate DLL."
    create_backup
    echo "Backup: $CURRENT_BACKUP"

    local bundle tmp
    bundle="$(cat "$CURRENT_BACKUP/bundle.path")"
    tmp="$(mktemp -d /tmp/megas4-install.XXXXXX)"
    cp "$CURRENT_BACKUP/thirdparty.js" "$tmp/thirdparty.js"
    cp "$CURRENT_BACKUP/files-bundle.js" "$tmp/files-bundle.js"
    cp "$CURRENT_BACKUP/web.appsettings.config" "$tmp/web.appsettings.config"

    printf '\n\n' >> "$tmp/thirdparty.js"
    cat "$EXTENSION" >> "$tmp/thirdparty.js"
    printf '\n\n' >> "$tmp/files-bundle.js"
    cat "$EXTENSION" >> "$tmp/files-bundle.js"

    python3 - "$tmp/web.appsettings.config" "$EXPECTED_ENABLE" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
expected = sys.argv[2]
text = p.read_text(encoding="utf-8")
needle = f'<add key="files.thirdparty.enable" value="{expected}" />'
replacement = f'<add key="files.thirdparty.enable" value="{expected},megas4" />'
if text.count(needle) != 1:
    raise SystemExit("validated files.thirdparty.enable anchor not found exactly once")
p.write_text(text.replace(needle, replacement, 1), encoding="utf-8")
PY

    [ "$(grep -cF "$MARKER" "$tmp/thirdparty.js")" -eq 1 ] || fail "patched source JS marker count invalid"
    [ "$(grep -cF "$MARKER" "$tmp/files-bundle.js")" -eq 1 ] || fail "patched bundle marker count invalid"
    grep -Fq 'value="box,dropboxv2,docusign,google,onedrive,sharepoint,nextcloud,owncloud,webdav,kdrive,yandex,megas4"' "$tmp/web.appsettings.config" \
        || fail "patched config validation failed"

    MUTATED=1
    docker cp "$CANDIDATE_DLL" "$C:$LIVE_DLL"
    docker cp "$tmp/thirdparty.js" "$C:$LIVE_JS"
    docker cp "$tmp/files-bundle.js" "$C:$bundle"
    docker cp "$tmp/web.appsettings.config" "$C:$LIVE_CONFIG"

    restore_meta "$LIVE_DLL" "$CURRENT_BACKUP/dll.meta"
    restore_meta "$LIVE_JS" "$CURRENT_BACKUP/js.meta"
    restore_meta "$bundle" "$CURRENT_BACKUP/bundle.meta"
    restore_meta "$LIVE_CONFIG" "$CURRENT_BACKUP/config.meta"

    rm -rf "$tmp"

    docker restart "$C" >/dev/null
    sleep 7
    [ "$(docker inspect -f '{{.State.Running}}' "$C")" = "true" ] || fail "CommunityServer did not return after restart"

    [ "$(container_hash "$LIVE_DLL")" = "$EXPECTED_MEGA_DLL" ] || fail "post-install DLL hash mismatch"
    docker exec "$C" monodis --typedef "$LIVE_DLL" | grep -q 'MegaS4ProviderInfo' || fail "live DLL CLR validation failed"
    [ "$(docker exec "$C" grep -aFc "$MARKER" "$LIVE_JS")" -eq 1 ] || fail "live source JS marker count invalid"
    [ "$(docker exec "$C" grep -aFc "$MARKER" "$bundle")" -eq 1 ] || fail "live bundle marker count invalid"
    docker exec "$C" grep -F 'key="files.thirdparty.enable"' "$LIVE_CONFIG" | grep -Fq 'megas4' || fail "live config did not enable megas4"

    printf '%s\n' "$CURRENT_BACKUP" > "$LATEST_FILE"
    MUTATED=0

    echo
    echo "PASS — MEGA S4 installed and validated."
    echo "Rollback backup: $CURRENT_BACKUP"
    echo "Hard-refresh the browser before testing Connected Clouds."
}

rollback_mode() {
    require_container
    [ -s "$LATEST_FILE" ] || fail "no recorded MEGA S4 backup in $LATEST_FILE"
    CURRENT_BACKUP="$(cat "$LATEST_FILE")"
    rollback_from_backup "$CURRENT_BACKUP"

    [ "$(container_hash "$LIVE_DLL")" = "$EXPECTED_STOCK_DLL" ] || fail "rollback DLL hash did not return to stock"
    [ "$(container_hash "$LIVE_JS")" = "$EXPECTED_STOCK_JS" ] || fail "rollback thirdparty.js hash did not return to stock"
    [ "$(container_hash "$LIVE_XSL")" = "$EXPECTED_STOCK_XSL" ] || fail "rollback XSL hash did not return to stock"
    rm -f "$LATEST_FILE"
    echo "PASS — MEGA S4 rollback completed and stock hashes restored."
}

case "$MODE" in
    install) install_mode ;;
    status) status ;;
    rollback) rollback_mode ;;
    *)
        echo "Usage: $0 {install|status|rollback}" >&2
        exit 2
        ;;
esac
