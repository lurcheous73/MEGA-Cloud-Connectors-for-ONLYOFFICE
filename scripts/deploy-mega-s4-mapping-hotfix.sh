#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-status}"
REPO="${REPO:-/opt/mega-cloud-connectors-for-onlyoffice}"
C="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
DB="${MYSQL_CONTAINER:-onlyoffice-mysql-server}"
IMAGE="${IMAGE:-onlyoffice/communityserver:12.8.0.1971}"
CANDIDATE="${MEGA_S4_DLL:-/opt/communityserver-megas4-dev/web/studio/ASC.Web.Studio/bin/ASC.Files.Thirdparty.dll}"
LIVE="/var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll"

REQUIRED_FIX_COMMIT="88c77d7b82c5228e2bea34d95ae9866d8223ec3f"
EXPECTED_OLD_HASH="98df3165b21b2011899f17d773f3695437706d01fdcc8e3899303462157acf01"
EXPECTED_NEW_HASH="73427e0218d2a19a91cd6e9ceb0f04f137ffba14f6956c754a039474128d0e6a"

BACKUP_ROOT="/var/backups/mega-cloud-connectors-for-onlyoffice"
STATE_DIR="/var/lib/mega-cloud-connectors-for-onlyoffice"
STATE_FILE="$STATE_DIR/mega-s4-mapping-hotfix.state"

fail() { echo "FAIL: $*" >&2; exit 1; }
chash() { docker exec "$C" sha256sum "$LIVE" | awk '{print $1}'; }

mega_rows() {
    docker exec "$DB" sh -lc '
        mysql --batch --raw --skip-column-names \
          -uroot -p"$MYSQL_ROOT_PASSWORD" onlyoffice \
          -e "SELECT COUNT(*) FROM files_thirdparty_account WHERE LOWER(provider)=\"megas4\";"
    ' 2>/dev/null | tr -d '\r'
}

old_mapping_rows() {
    docker exec "$DB" sh -lc '
        mysql --batch --raw --skip-column-names \
          -uroot -p"$MYSQL_ROOT_PASSWORD" onlyoffice \
          -e "SELECT COUNT(*) FROM files_thirdparty_id_mapping WHERE id LIKE \"megas4-%\" OR hash_id LIKE \"megas4-%\";"
    ' 2>/dev/null | tr -d '\r'
}

validate_candidate() {
    test -s "$CANDIDATE" || fail "candidate DLL missing: $CANDIDATE"
    local h
    h="$(sha256sum "$CANDIDATE" | awk '{print $1}')"
    [[ "$h" == "$EXPECTED_NEW_HASH" ]] || fail "candidate hash mismatch: $h"

    local dir base
    dir="$(dirname "$CANDIDATE")"
    base="$(basename "$CANDIDATE")"
    docker run --rm \
      --entrypoint /bin/bash \
      -e DLL_BASE="$base" \
      -v "$dir:/candidate:ro" \
      "$IMAGE" <<'VERIFY'
set -euo pipefail
DLL="/candidate/$DLL_BASE"
monodis --assembly "$DLL" | grep -q 'Name:          ASC.Files.Thirdparty'
monodis --typedef "$DLL" | grep -q 'ASC.Files.Thirdparty.MegaS4.MegaS4DaoSelector'
monodis --userstrings "$DLL" | grep -Fq 'sbox-megas4-'
VERIFY
    echo "PASS: candidate hash and mapping-safe prefix"
}

preflight() {
    echo "============================================================"
    echo " MEGA S4 — MAPPING HOTFIX EXACT-HASH GATE"
    echo "============================================================"

    test -d "$REPO/.git" || fail "connector checkout missing: $REPO"
    git -C "$REPO" merge-base --is-ancestor "$REQUIRED_FIX_COMMIT" HEAD \
        || fail "checkout does not contain mapping fix $REQUIRED_FIX_COMMIT"
    [[ -z "$(git -C "$REPO" status --porcelain)" ]] || fail "connector worktree is not clean"
    echo "PASS: connector checkout contains reviewed mapping fix"

    docker inspect "$C" >/dev/null 2>&1 || fail "CommunityServer container missing"
    docker inspect "$DB" >/dev/null 2>&1 || fail "MySQL container missing"
    [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer is not running"
    [[ "$(docker inspect -f '{{.State.Running}}' "$DB")" == "true" ]] || fail "MySQL is not running"
    [[ "$(docker inspect -f '{{.Config.Image}}' "$C")" == "$IMAGE" ]] || fail "CommunityServer image mismatch"

    local live_hash
    live_hash="$(chash)"
    [[ "$live_hash" == "$EXPECTED_OLD_HASH" ]] || fail "live DLL is not expected pre-fix build: $live_hash"
    echo "PASS: exact pre-fix live DLL hash"

    validate_candidate

    local rows mappings
    rows="$(mega_rows)"
    [[ "$rows" == "0" ]] || fail "MegaS4 account rows exist ($rows); clean them before changing ID scheme"
    echo "PASS: no MegaS4 account rows"

    mappings="$(old_mapping_rows)"
    [[ "$mappings" == "0" ]] || fail "old megas4-* mapping rows exist ($mappings); refuse automatic deploy"
    echo "PASS: no stale old-prefix mapping rows"

    echo "============================================================"
    echo " PASS — HOTFIX PRE-FLIGHT GREEN"
    echo "============================================================"
}

install_hotfix() {
    preflight

    local stamp backup mutated=0
    stamp="$(date +%Y%m%d-%H%M%S)"
    backup="$BACKUP_ROOT/mega-s4-mapping-hotfix-$stamp"
    mkdir -p "$backup" "$STATE_DIR"
    chmod 700 "$backup" "$STATE_DIR"

    docker cp "$C:$LIVE" "$backup/ASC.Files.Thirdparty.dll" >/dev/null
    [[ "$(sha256sum "$backup/ASC.Files.Thirdparty.dll" | awk '{print $1}')" == "$EXPECTED_OLD_HASH" ]] \
        || fail "backup hash mismatch"

    cat >"$backup/MANIFEST" <<EOF
created=$stamp
container=$C
live_path=$LIVE
old_hash=$EXPECTED_OLD_HASH
new_hash=$EXPECTED_NEW_HASH
candidate=$CANDIDATE
EOF
    sha256sum "$backup/ASC.Files.Thirdparty.dll" >"$backup/SHA256SUMS"

    rollback_on_error() {
        local rc=$?
        trap - ERR
        set +e
        if [[ "$mutated" == "1" ]]; then
            echo
            echo "ERROR after live mutation — restoring previous DLL automatically..." >&2
            docker stop "$C" >/dev/null 2>&1 || true
            docker cp "$backup/ASC.Files.Thirdparty.dll" "$C:$LIVE" >/dev/null 2>&1 || true
            docker start "$C" >/dev/null 2>&1 || true
            sleep 8
            local restored
            restored="$(chash 2>/dev/null || true)"
            if [[ "$restored" == "$EXPECTED_OLD_HASH" ]]; then
                echo "AUTO-ROLLBACK PASS: restored $EXPECTED_OLD_HASH" >&2
            else
                echo "AUTO-ROLLBACK WARNING: live hash is $restored" >&2
            fi
        fi
        exit "$rc"
    }
    trap rollback_on_error ERR

    echo
    echo "=== STOP COMMUNITYSERVER ==="
    docker stop "$C" >/dev/null
    [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "false" ]] || fail "CommunityServer did not stop"

    echo "=== INSTALL MAPPING-FIX DLL ==="
    mutated=1
    docker cp "$CANDIDATE" "$C:$LIVE" >/dev/null

    local stopped_hash
    stopped_hash="$(docker exec "$C" sha256sum "$LIVE" | awk '{print $1}')"
    [[ "$stopped_hash" == "$EXPECTED_NEW_HASH" ]] || fail "copied DLL hash mismatch: $stopped_hash"
    echo "PASS: exact new DLL installed while stopped"

    echo "=== START COMMUNITYSERVER ==="
    docker start "$C" >/dev/null
    sleep 10
    [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer failed to start"

    local final_hash
    final_hash="$(chash)"
    [[ "$final_hash" == "$EXPECTED_NEW_HASH" ]] || fail "post-start live DLL hash mismatch: $final_hash"

    printf '%s\n' "$backup" >"$STATE_FILE"
    chmod 600 "$STATE_FILE"
    mutated=0
    trap - ERR

    echo
    echo "============================================================"
    echo " PASS — MEGA S4 MAPPING HOTFIX DEPLOYED"
    echo " Live DLL: $final_hash"
    echo " Backup  : $backup"
    echo " DB      : unchanged"
    echo " JS/UI   : unchanged"
    echo "============================================================"
}

status_hotfix() {
    docker inspect "$C" >/dev/null 2>&1 || fail "CommunityServer container missing"
    local h rows mappings
    h="$(chash)"
    rows="$(mega_rows)"
    mappings="$(old_mapping_rows)"

    echo "Live DLL : $h"
    case "$h" in
        "$EXPECTED_NEW_HASH") echo "State    : MAPPING HOTFIX CURRENT" ;;
        "$EXPECTED_OLD_HASH") echo "State    : PRE-FIX MEGA DLL" ;;
        *) echo "State    : UNKNOWN DLL HASH" ;;
    esac
    echo "Mega rows: $rows"
    echo "Old maps : $mappings"
    if [[ -s "$STATE_FILE" ]]; then
        echo "Backup   : $(cat "$STATE_FILE")"
    else
        echo "Backup   : no hotfix state file"
    fi
}

rollback_hotfix() {
    [[ -s "$STATE_FILE" ]] || fail "no mapping-hotfix state file"
    local backup rows live_hash
    backup="$(cat "$STATE_FILE")"
    test -d "$backup" || fail "backup directory missing: $backup"
    test -s "$backup/ASC.Files.Thirdparty.dll" || fail "backup DLL missing"
    [[ "$(sha256sum "$backup/ASC.Files.Thirdparty.dll" | awk '{print $1}')" == "$EXPECTED_OLD_HASH" ]] \
        || fail "backup DLL hash mismatch"

    rows="$(mega_rows)"
    [[ "$rows" == "0" ]] || fail "MegaS4 account rows now exist ($rows); refusing rollback across ID schemes"

    live_hash="$(chash)"
    [[ "$live_hash" == "$EXPECTED_NEW_HASH" ]] || fail "live DLL is not mapping-hotfix build: $live_hash"

    docker stop "$C" >/dev/null
    docker cp "$backup/ASC.Files.Thirdparty.dll" "$C:$LIVE" >/dev/null
    [[ "$(docker exec "$C" sha256sum "$LIVE" | awk '{print $1}')" == "$EXPECTED_OLD_HASH" ]] \
        || fail "restored DLL hash mismatch while stopped"
    docker start "$C" >/dev/null
    sleep 10
    [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer failed to restart"
    [[ "$(chash)" == "$EXPECTED_OLD_HASH" ]] || fail "rollback live hash mismatch"

    rm -f "$STATE_FILE"
    echo "PASS — mapping hotfix rolled back to $EXPECTED_OLD_HASH"
}

case "$MODE" in
    preflight) preflight ;;
    install) install_hotfix ;;
    status) status_hotfix ;;
    rollback) rollback_hotfix ;;
    *) echo "Usage: $0 {preflight|install|status|rollback}" >&2; exit 2 ;;
esac
