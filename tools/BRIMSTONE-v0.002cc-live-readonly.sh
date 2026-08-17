#!/usr/bin/env bash
# BRIMSTONE CUSTOM CODE — v0.002cc first controlled live read-only deployment.
#
# Stage 1 only:
#   * rebuild + disposable smoke current branch
#   * back up exact live ASC.Files.Thirdparty.dll
#   * install candidate DLL
#   * install pinned official MEGAcmd engine at the connector's default path
#   * copy an already-authenticated test slot into protected live Brimstone state
#   * prove the copied live session can resume with no password
#   * create NO ONLYOFFICE provider row and NO mapping row
#
# CommunityServer is the only container stopped/started. MySQL must not restart.
set -Eeuo pipefail

MODE="${1:-preflight}"
REPO="${REPO:-/opt/mega-cloud-connectors-for-onlyoffice}"
C="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
DB="${MYSQL_CONTAINER:-onlyoffice-mysql-server}"
IMAGE="${IMAGE:-onlyoffice/communityserver:12.8.0.1971}"
BRANCH="v0.002cc-mega-cloud"
VERSION_FILE="$REPO/src/mega-cloud/VERSION"
RUNTIME_SMOKE="$REPO/tools/BRIMSTONE-v0.002cc-runtime-smoke.sh"

SOURCE_SLOT="${SOURCE_SLOT:-test1}"
TARGET_SLOT="${TARGET_SLOT:-brimstone-v0002-test1}"

LIVE_DLL="/var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll"
EXPECTED_OLD="62bdff5b75ab9db37108a6f772a92240805879f0cf400bb8c2813d2aa68b679f"
CANDIDATE="$REPO/build/communityserver-v0.002cc-src/web/studio/ASC.Web.Studio/bin/ASC.Files.Thirdparty.dll"

HOST_ENGINE="$REPO/build/mega-cloud-v0.001cc/megacmd-prefix"
HOST_ENGINE_SERVER="$HOST_ENGINE/usr/bin/mega-cmd-server"
EXPECTED_ENGINE_SERVER="c8020ef2b964fad0699aad172cbb14f452c29eaf1a5067ac1c786d4244a2f4d2"
HOST_SOURCE_STATE="$REPO/build/mega-cloud-v0.001cc/megacmd-state/$SOURCE_SLOT"
HOST_SOURCE_SESSION="$HOST_SOURCE_STATE/home/.megaCmd/session"

TARGET_ENGINE="/opt/brimstone/mega-cloud/megacmd"
TARGET_STATE_ROOT="/var/lib/brimstone/mega-cloud/providers"
TARGET_STATE="$TARGET_STATE_ROOT/$TARGET_SLOT"
TARGET_HOME="$TARGET_STATE/home"
TARGET_SESSION="$TARGET_HOME/.megaCmd/session"
TARGET_SOCKET="brimstone-megacc-$TARGET_SLOT.socket"

BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/mega-cloud-connectors-for-onlyoffice}"
STATE_DIR="${STATE_DIR:-/var/lib/mega-cloud-connectors-for-onlyoffice}"
STATE="$STATE_DIR/v0.002cc-mega-cloud-live-readonly.state"

fail(){ echo "BRIMSTONE FAIL: $*" >&2; exit 1; }

validate_slot(){
    local value="$1" label="$2"
    [[ "$value" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || fail "$label contains invalid characters or is longer than 64 characters"
}

live_hash(){ docker exec "$C" sha256sum "$LIVE_DLL" | awk '{print $1}'; }
mysql_started(){ docker inspect -f '{{.State.StartedAt}}' "$DB"; }
mysql_restart_count(){ docker inspect -f '{{.RestartCount}}' "$DB"; }
source_session_hash(){ sha256sum "$HOST_SOURCE_SESSION" | awk '{print $1}'; }

mysql_scalar(){
    local sql="$1"
    docker exec -e SQL="$sql" "$DB" sh -lc 'mysql --batch --raw --skip-column-names -uroot -p"$MYSQL_ROOT_PASSWORD" onlyoffice -e "$SQL"' 2>/dev/null | tr -d '\r'
}

cloud_rows(){
    mysql_scalar "SELECT COUNT(*) FROM files_thirdparty_account WHERE LOWER(provider)='brimstonemegacloud';"
}

cloud_maps(){
    mysql_scalar "SELECT COUNT(*) FROM files_thirdparty_id_mapping WHERE id LIKE 'sboxbrimstonemegacc-%' OR hash_id LIKE 'sboxbrimstonemegacc-%';"
}

all_provider_rows(){ mysql_scalar "SELECT COUNT(*) FROM files_thirdparty_account;"; }
all_mapping_rows(){ mysql_scalar "SELECT COUNT(*) FROM files_thirdparty_id_mapping;"; }

container_path_exists(){ docker exec "$C" test -e "$1" >/dev/null 2>&1; }
container_path_missing(){ ! container_path_exists "$1"; }

validate_candidate(){
    [[ -s "$CANDIDATE" ]] || fail "candidate missing after runtime smoke: $CANDIDATE"
    local dir
    dir="$(dirname "$CANDIDATE")"
    docker run --rm -i --entrypoint /bin/bash -v "$dir:/candidate:ro" "$IMAGE" -s <<'CHECK'
set -Eeuo pipefail
DLL=/candidate/ASC.Files.Thirdparty.dll
TYPES="$(monodis --typedef "$DLL")"
STRINGS="$(monodis --userstrings "$DLL")"
grep -Fq 'ASC.Files.Thirdparty.MegaS4.MegaS4DaoSelector' <<<"$TYPES"
grep -Fq 'ASC.Files.Thirdparty.BrimstoneMegaCloud.BrimstoneMegaCloudProviderInfo' <<<"$TYPES"
grep -Fq 'ASC.Files.Thirdparty.BrimstoneMegaCloud.BrimstoneMegaCloudDaoSelector' <<<"$TYPES"
grep -Fq 'ASC.Files.Thirdparty.BrimstoneMegaCloud.BrimstoneMegaCloudFolderDao' <<<"$TYPES"
grep -Fq 'ASC.Files.Thirdparty.BrimstoneMegaCloud.BrimstoneMegaCloudFileDao' <<<"$TYPES"
grep -Fq 'sboxbrimstonemegacc-' <<<"$STRINGS"
grep -Fq 'Brimstone MEGA Cloud v0.002cc is read-only.' <<<"$STRINGS"
echo 'PASS: live candidate CLR contract contains accepted S4 + Brimstone Cloud read-only provider'
CHECK
}

preflight(){
    echo "============================================================"
    echo " BRIMSTONE MEGA CLOUD v0.002cc — LIVE READ-ONLY PREFLIGHT"
    echo "============================================================"

    validate_slot "$SOURCE_SLOT" "SOURCE_SLOT"
    validate_slot "$TARGET_SLOT" "TARGET_SLOT"
    [[ "$SOURCE_SLOT" != "$TARGET_SLOT" ]] || fail "TARGET_SLOT must differ from the disposable source slot"

    [[ -d "$REPO/.git" ]] || fail "repo missing: $REPO"
    [[ "$(git -C "$REPO" branch --show-current)" == "$BRANCH" ]] || fail "expected branch $BRANCH"
    [[ -z "$(git -C "$REPO" status --porcelain --untracked-files=normal)" ]] || fail "repo worktree is dirty"
    [[ "$(cat "$VERSION_FILE")" == "0.002cc" ]] || fail "unexpected MEGA Cloud VERSION"
    [[ -s "$RUNTIME_SMOKE" ]] || fail "runtime smoke gate missing"

    docker inspect "$C" >/dev/null 2>&1 || fail "CommunityServer container missing"
    docker inspect "$DB" >/dev/null 2>&1 || fail "MySQL container missing"
    [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer is not running"
    [[ "$(docker inspect -f '{{.State.Running}}' "$DB")" == "true" ]] || fail "MySQL is not running"
    [[ "$(docker inspect -f '{{.Config.Image}}' "$C")" == "$IMAGE" ]] || fail "CommunityServer image mismatch"
    [[ "$(live_hash)" == "$EXPECTED_OLD" ]] || fail "unexpected live DLL: $(live_hash)"

    [[ ! -e "$STATE" ]] || fail "prior v0.002cc deployment state exists: $STATE"
    container_path_missing "$TARGET_ENGINE" || fail "target MEGAcmd engine path already exists: $TARGET_ENGINE"
    container_path_missing "$TARGET_STATE" || fail "target Brimstone provider state already exists: $TARGET_STATE"

    [[ -x "$HOST_ENGINE_SERVER" ]] || fail "accepted host MEGAcmd engine missing"
    [[ "$(sha256sum "$HOST_ENGINE_SERVER" | awk '{print $1}')" == "$EXPECTED_ENGINE_SERVER" ]] || fail "host MEGAcmd server hash mismatch"
    [[ -s "$HOST_SOURCE_SESSION" ]] || fail "source saved MEGA session missing for slot $SOURCE_SLOT"

    [[ "$(cloud_rows)" == "0" ]] || fail "BrimstoneMegaCloud provider rows already exist; inspect before first deployment"
    [[ "$(cloud_maps)" == "0" ]] || fail "BrimstoneMegaCloud mapping rows already exist; inspect before first deployment"

    local mysql_started_before mysql_restarts_before
    mysql_started_before="$(mysql_started)"
    mysql_restarts_before="$(mysql_restart_count)"

    echo "branch:              $(git -C "$REPO" branch --show-current)"
    echo "head:                $(git -C "$REPO" rev-parse HEAD)"
    echo "live DLL:            $(live_hash)"
    echo "MEGAcmd server:      $EXPECTED_ENGINE_SERVER"
    echo "source slot:         $SOURCE_SLOT (read-only source)"
    echo "target live slot:    $TARGET_SLOT"
    echo "Cloud provider rows: 0"
    echo "Cloud mapping rows:  0"
    echo "MySQL StartedAt:     $mysql_started_before"
    echo "MySQL RestartCount:  $mysql_restarts_before"
    echo

    echo "=== RE-RUN ACCEPTED DISPOSABLE SMOKE AGAINST CURRENT CLEAN HEAD ==="
    bash "$RUNTIME_SMOKE" "$SOURCE_SLOT"
    validate_candidate

    [[ "$(live_hash)" == "$EXPECTED_OLD" ]] || fail "live DLL changed during preflight smoke"
    [[ "$(mysql_started)" == "$mysql_started_before" ]] || fail "MySQL StartedAt changed during preflight"
    [[ "$(mysql_restart_count)" == "$mysql_restarts_before" ]] || fail "MySQL RestartCount changed during preflight"
    [[ "$(cloud_rows)" == "0" ]] || fail "Cloud provider rows appeared during preflight"
    [[ "$(cloud_maps)" == "0" ]] || fail "Cloud mappings appeared during preflight"

    echo
    echo "PASS: v0.002cc live read-only preflight"
    echo "candidate:           $(sha256sum "$CANDIDATE" | awk '{print $1}')"
    echo "source session hash: $(source_session_hash)"
    echo "live stack:          NOT MODIFIED"
    echo "database:            NOT TOUCHED"
    echo "MySQL:               NOT RESTARTED"
}

remove_live_cloud_runtime(){
    # Called only after CommunityServer has been returned to the old DLL.
    docker exec "$C" rm -rf "$TARGET_ENGINE" "$TARGET_STATE" >/dev/null 2>&1 || true
    docker exec "$C" sh -lc 'rmdir /opt/brimstone/mega-cloud 2>/dev/null || true; rmdir /opt/brimstone 2>/dev/null || true; rmdir /var/lib/brimstone/mega-cloud/providers 2>/dev/null || true; rmdir /var/lib/brimstone/mega-cloud 2>/dev/null || true; rmdir /var/lib/brimstone 2>/dev/null || true' >/dev/null 2>&1 || true
}

restore_from_backup(){
    local backup="$1"
    [[ -s "$backup/ASC.Files.Thirdparty.dll" ]] || fail "rollback DLL missing: $backup"
    [[ "$(sha256sum "$backup/ASC.Files.Thirdparty.dll" | awk '{print $1}')" == "$EXPECTED_OLD" ]] || fail "rollback DLL hash mismatch"

    docker stop "$C" >/dev/null || true
    docker cp "$backup/ASC.Files.Thirdparty.dll" "$C:$LIVE_DLL" >/dev/null
    docker start "$C" >/dev/null
    sleep 10
    [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer failed to return during rollback"
    [[ "$(live_hash)" == "$EXPECTED_OLD" ]] || fail "rollback live DLL hash mismatch: $(live_hash)"
    remove_live_cloud_runtime
}

install(){
    preflight

    local candidate_hash source_hash_before rows_before maps_before mysql_started_before mysql_restarts_before
    candidate_hash="$(sha256sum "$CANDIDATE" | awk '{print $1}')"
    source_hash_before="$(source_session_hash)"
    rows_before="$(all_provider_rows)"
    maps_before="$(all_mapping_rows)"
    mysql_started_before="$(mysql_started)"
    mysql_restarts_before="$(mysql_restart_count)"

    local stamp backup mutated=0
    stamp="$(date +%Y%m%d-%H%M%S)"
    backup="$BACKUP_ROOT/brimstone-mega-cloud-v0.002cc-live-readonly-$stamp"
    mkdir -p "$backup" "$STATE_DIR"
    chmod 700 "$backup" "$STATE_DIR"

    docker cp "$C:$LIVE_DLL" "$backup/ASC.Files.Thirdparty.dll" >/dev/null
    [[ "$(sha256sum "$backup/ASC.Files.Thirdparty.dll" | awk '{print $1}')" == "$EXPECTED_OLD" ]] || fail "backup DLL hash mismatch"

    cat > "$backup/MANIFEST" <<EOF
BRIMSTONE=MEGA-CLOUD-v0.002cc-live-readonly
created=$stamp
branch=$BRANCH
head=$(git -C "$REPO" rev-parse HEAD)
old_dll=$EXPECTED_OLD
new_dll=$candidate_hash
engine_server=$EXPECTED_ENGINE_SERVER
source_slot=$SOURCE_SLOT
target_slot=$TARGET_SLOT
source_session_hash=$source_hash_before
provider_rows_before=$rows_before
mapping_rows_before=$maps_before
mysql_started_before=$mysql_started_before
mysql_restart_count_before=$mysql_restarts_before
EOF
    (cd "$backup" && sha256sum ASC.Files.Thirdparty.dll MANIFEST > SHA256SUMS && sha256sum -c SHA256SUMS >/dev/null)

    rollback_on_error(){
        local rc=$?
        trap - ERR
        if [[ "$mutated" == "1" ]]; then
            echo "BRIMSTONE ERROR after live mutation — restoring pre-Cloud baseline" >&2
            restore_from_backup "$backup" || true
        fi
        exit "$rc"
    }
    trap rollback_on_error ERR

    mutated=1
    echo
    echo "=== PREPARE EMPTY BRIMSTONE LIVE RUNTIME PATHS ==="
    docker exec "$C" mkdir -p "$TARGET_ENGINE" "$TARGET_STATE"

    echo "=== STOP COMMUNITYSERVER ONLY ==="
    docker stop "$C" >/dev/null

    echo "=== INSTALL PINNED MEGACMD ENGINE ==="
    docker cp "$HOST_ENGINE/." "$C:$TARGET_ENGINE/" >/dev/null

    echo "=== INSTALL COPIED AUTHENTICATED TEST SLOT ==="
    docker cp "$HOST_SOURCE_STATE/." "$C:$TARGET_STATE/" >/dev/null

    echo "=== INSTALL EXACT CURRENT v0.002cc CANDIDATE DLL ==="
    docker cp "$CANDIDATE" "$C:$LIVE_DLL" >/dev/null

    echo "=== START COMMUNITYSERVER ==="
    docker start "$C" >/dev/null
    sleep 10

    [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer failed to return"
    [[ "$(live_hash)" == "$candidate_hash" ]] || fail "post-start live DLL hash mismatch: $(live_hash)"

    echo "=== SECURE + VERIFY LIVE BRIMSTONE RUNTIME ==="
    docker exec "$C" chmod -R go-rwx "$TARGET_STATE"
    docker exec "$C" chmod 700 "$(dirname "$TARGET_STATE_ROOT")" "$TARGET_STATE_ROOT" "$TARGET_STATE" "$TARGET_HOME"
    docker exec "$C" test -s "$TARGET_SESSION" || fail "copied live MEGA session missing"
    [[ "$(docker exec "$C" sha256sum "$TARGET_ENGINE/usr/bin/mega-cmd-server" | awk '{print $1}')" == "$EXPECTED_ENGINE_SERVER" ]] || fail "live MEGAcmd server hash mismatch"

    echo "=== LIVE COPIED-SESSION RESUME TEST (NO PASSWORD) ==="
    docker exec \
        -e HOME="$TARGET_HOME" \
        -e MEGACMD_SOCKET_NAME="$TARGET_SOCKET" \
        -e LD_LIBRARY_PATH="$TARGET_ENGINE/opt/megacmd/lib" \
        "$C" timeout 180 "$TARGET_ENGINE/usr/bin/mega-exec" whoami >/dev/null 2>&1 || fail "live copied session whoami failed"
    docker exec \
        -e HOME="$TARGET_HOME" \
        -e MEGACMD_SOCKET_NAME="$TARGET_SOCKET" \
        -e LD_LIBRARY_PATH="$TARGET_ENGINE/opt/megacmd/lib" \
        "$C" timeout 180 "$TARGET_ENGINE/usr/bin/mega-exec" ls / >/dev/null 2>&1 || fail "live copied session root browse failed"
    echo "PASS: live container resumed copied MEGA session and browsed root without password"

    [[ "$(all_provider_rows)" == "$rows_before" ]] || fail "provider account row count changed during deployment"
    [[ "$(all_mapping_rows)" == "$maps_before" ]] || fail "third-party mapping row count changed during deployment"
    [[ "$(cloud_rows)" == "0" ]] || fail "Cloud provider row appeared during stage-1 deployment"
    [[ "$(cloud_maps)" == "0" ]] || fail "Cloud mapping row appeared during stage-1 deployment"
    [[ "$(source_session_hash)" == "$source_hash_before" ]] || fail "host source saved MEGA session changed during deployment"
    [[ "$(mysql_started)" == "$mysql_started_before" ]] || fail "MySQL StartedAt changed during deployment"
    [[ "$(mysql_restart_count)" == "$mysql_restarts_before" ]] || fail "MySQL RestartCount changed during deployment"

    cat > "$STATE" <<EOF
backup=$backup
old_dll=$EXPECTED_OLD
new_dll=$candidate_hash
engine_server=$EXPECTED_ENGINE_SERVER
target_engine=$TARGET_ENGINE
target_state=$TARGET_STATE
target_slot=$TARGET_SLOT
cloud_rows=0
cloud_maps=0
source_session_hash=$source_hash_before
installed=$stamp
EOF
    chmod 600 "$STATE"

    trap - ERR
    mutated=0

    echo
    echo "============================================================"
    echo " PASS — v0.002cc LIVE READ-ONLY STAGE 1 DEPLOYED"
    echo "============================================================"
    echo "Live DLL      : $(live_hash)"
    echo "MEGAcmd server: $(docker exec "$C" sha256sum "$TARGET_ENGINE/usr/bin/mega-cmd-server" | awk '{print $1}')"
    echo "Target slot   : $TARGET_SLOT"
    echo "Cloud rows    : $(cloud_rows)"
    echo "Cloud maps    : $(cloud_maps)"
    echo "MySQL Started : $(mysql_started)"
    echo "MySQL restarts: $(mysql_restart_count)"
    echo "Backup        : $backup"
    echo "Database      : NOT TOUCHED"
    echo "Next          : controlled creation of ONE BrimstoneMegaCloud test provider row"
}

status(){
    echo "=== BRIMSTONE MEGA CLOUD v0.002cc LIVE READ-ONLY STATUS ==="
    echo "Live DLL      : $(live_hash 2>/dev/null || echo unavailable)"
    echo "Cloud rows    : $(cloud_rows 2>/dev/null || echo unavailable)"
    echo "Cloud maps    : $(cloud_maps 2>/dev/null || echo unavailable)"
    echo "MySQL Started : $(mysql_started 2>/dev/null || echo unavailable)"
    echo "MySQL restarts: $(mysql_restart_count 2>/dev/null || echo unavailable)"
    if container_path_exists "$TARGET_ENGINE/usr/bin/mega-cmd-server"; then
        echo "MEGAcmd server: $(docker exec "$C" sha256sum "$TARGET_ENGINE/usr/bin/mega-cmd-server" | awk '{print $1}')"
    else
        echo "MEGAcmd server: not installed"
    fi
    if container_path_exists "$TARGET_SESSION"; then
        echo "Target session: present"
    else
        echo "Target session: absent"
    fi
    [[ -s "$STATE" ]] && cat "$STATE"
}

rollback(){
    [[ -s "$STATE" ]] || fail "no v0.002cc live deployment state file"

    local backup expected_new expected_cloud_rows expected_cloud_maps mysql_started_before mysql_restarts_before
    backup="$(sed -n 's/^backup=//p' "$STATE" | head -n1)"
    expected_new="$(sed -n 's/^new_dll=//p' "$STATE" | head -n1)"
    expected_cloud_rows="$(sed -n 's/^cloud_rows=//p' "$STATE" | head -n1)"
    expected_cloud_maps="$(sed -n 's/^cloud_maps=//p' "$STATE" | head -n1)"
    [[ -d "$backup" ]] || fail "recorded backup missing: $backup"
    [[ "$(live_hash)" == "$expected_new" ]] || fail "live DLL is not the recorded v0.002cc candidate"
    [[ "$(cloud_rows)" == "$expected_cloud_rows" ]] || fail "Cloud provider rows changed; remove/inspect test connection before rollback"
    [[ "$(cloud_maps)" == "$expected_cloud_maps" ]] || fail "Cloud mapping rows changed; remove/inspect mappings before rollback"

    mysql_started_before="$(mysql_started)"
    mysql_restarts_before="$(mysql_restart_count)"
    restore_from_backup "$backup"

    [[ "$(mysql_started)" == "$mysql_started_before" ]] || fail "MySQL StartedAt changed during rollback"
    [[ "$(mysql_restart_count)" == "$mysql_restarts_before" ]] || fail "MySQL RestartCount changed during rollback"
    rm -f "$STATE"

    echo "PASS: rolled back v0.002cc live read-only stage to pre-Cloud DLL/runtime"
    status
}

case "$MODE" in
    preflight) preflight ;;
    install) install ;;
    status) status ;;
    rollback) rollback ;;
    *) echo "Usage: $0 {preflight|install|status|rollback}" >&2; exit 2 ;;
esac
