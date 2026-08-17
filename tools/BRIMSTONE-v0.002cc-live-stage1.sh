#!/usr/bin/env bash
# BRIMSTONE CUSTOM CODE — v0.002cc stage-1 live wrapper.
#
# Adds one safety property to BRIMSTONE-v0.002cc-live-readonly.sh:
# the copied MEGA session is re-owned to the ACTUAL live WebStudio/monoserve
# process UID:GID, the root-started probe server is stopped, and saved-session
# resume/root browse are then proved by starting MEGAcmd as that runtime user.
#
# On any post-install failure the recorded v0.002cc deployment is rolled back.
set -Eeuo pipefail

MODE="${1:-install}"
REPO="${REPO:-/opt/mega-cloud-connectors-for-onlyoffice}"
C="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
BASE="$REPO/tools/BRIMSTONE-v0.002cc-live-readonly.sh"
STATE="${STATE_DIR:-/var/lib/mega-cloud-connectors-for-onlyoffice}/v0.002cc-mega-cloud-live-readonly.state"

TARGET_SLOT="${TARGET_SLOT:-brimstone-v0002-test1}"
TARGET_ENGINE="/opt/brimstone/mega-cloud/megacmd"
TARGET_STATE_ROOT="/var/lib/brimstone/mega-cloud/providers"
TARGET_STATE="$TARGET_STATE_ROOT/$TARGET_SLOT"
TARGET_HOME="$TARGET_STATE/home"
TARGET_SESSION="$TARGET_HOME/.megaCmd/session"
TARGET_SOCKET="brimstone-megacc-$TARGET_SLOT.socket"

fail(){ echo "BRIMSTONE FAIL: $*" >&2; exit 1; }

runtime_uid_gid(){
    docker exec "$C" sh -lc '
set -eu
pid="$(systemctl show monoserve.service -p MainPID --value 2>/dev/null || true)"
if [ -z "$pid" ] || [ "$pid" = "0" ] || [ ! -r "/proc/$pid/status" ]; then
    pid="$(pgrep -o -f "[h]yperfastcgi|[f]astcgi-mono-server" 2>/dev/null || true)"
fi
[ -n "$pid" ] && [ "$pid" != "0" ] && [ -r "/proc/$pid/status" ] || exit 1
uid="$(awk '\''/^Uid:/{print $2; exit}'\'' "/proc/$pid/status")"
gid="$(awk '\''/^Gid:/{print $2; exit}'\'' "/proc/$pid/status")"
[ -n "$uid" ] && [ -n "$gid" ] || exit 1
printf "%s:%s\n" "$uid" "$gid"
'
}

stop_target_megacmd(){
    docker exec -e BRIMSTONE_TARGET_SOCKET="$TARGET_SOCKET" "$C" sh -lc '
set +e
for p in /proc/[0-9]*; do
    [ -r "$p/environ" ] || continue
    if tr "\000" "\n" < "$p/environ" 2>/dev/null | grep -Fxq "MEGACMD_SOCKET_NAME=$BRIMSTONE_TARGET_SOCKET"; then
        pid="${p#/proc/}"
        kill "$pid" 2>/dev/null || true
    fi
done
sleep 1
' >/dev/null 2>&1 || true
}

secure_state_for_runtime(){
    local ug="$1"
    docker exec "$C" test -s "$TARGET_SESSION" || fail "live copied MEGA session missing"

    # /var/lib/brimstone/mega-cloud is exclusively Brimstone Cloud state at
    # this milestone. Make the runtime user own it, keep parent traversal
    # private, and force directories/files to 0700/0600 respectively.
    docker exec "$C" chown -R "$ug" /var/lib/brimstone/mega-cloud
    docker exec "$C" sh -lc \
        'find /var/lib/brimstone/mega-cloud -type d -exec chmod 700 {} +; find /var/lib/brimstone/mega-cloud -type f -exec chmod 600 {} +'

    [[ "$(docker exec "$C" stat -c '%u:%g' "$TARGET_HOME")" == "$ug" ]] ||
        fail "Brimstone MEGA Cloud HOME ownership does not match WebStudio runtime"
    [[ "$(docker exec "$C" stat -c '%a' "$TARGET_HOME")" == "700" ]] ||
        fail "Brimstone MEGA Cloud HOME is not mode 0700"
}

runtime_resume_test(){
    local ug="$1"

    # The base stage-1 installer intentionally does an initial root probe.
    # Stop that exact per-slot server first so this test proves the WebStudio
    # identity can START its own MEGAcmd server and use the copied session.
    stop_target_megacmd

    echo "=== WEBSTUDIO-IDENTITY COPIED-SESSION RESUME TEST ==="
    docker exec -u "$ug" \
        -e HOME="$TARGET_HOME" \
        -e MEGACMD_SOCKET_NAME="$TARGET_SOCKET" \
        -e LD_LIBRARY_PATH="$TARGET_ENGINE/opt/megacmd/lib" \
        "$C" timeout 180 "$TARGET_ENGINE/usr/bin/mega-exec" whoami >/dev/null 2>&1 ||
        fail "WebStudio runtime identity could not resume copied MEGA session"

    docker exec -u "$ug" \
        -e HOME="$TARGET_HOME" \
        -e MEGACMD_SOCKET_NAME="$TARGET_SOCKET" \
        -e LD_LIBRARY_PATH="$TARGET_ENGINE/opt/megacmd/lib" \
        "$C" timeout 180 "$TARGET_ENGINE/usr/bin/mega-exec" ls / >/dev/null 2>&1 ||
        fail "WebStudio runtime identity could not browse MEGA root"

    echo "PASS: real WebStudio runtime identity started MEGAcmd, resumed saved session and browsed root"
}

install(){
    [[ -s "$BASE" ]] || fail "base v0.002cc live gate missing: $BASE"
    [[ ! -e "$STATE" ]] || fail "prior v0.002cc live deployment state exists: $STATE"

    local ug
    ug="$(runtime_uid_gid)" || fail "could not resolve live WebStudio/monoserve UID:GID"
    [[ "$ug" =~ ^[0-9]+:[0-9]+$ ]] || fail "invalid WebStudio runtime UID:GID: $ug"

    echo "============================================================"
    echo " BRIMSTONE MEGA CLOUD v0.002cc — LIVE STAGE 1"
    echo "============================================================"
    echo "WebStudio runtime UID:GID: $ug"
    echo "Provider rows to create   : 0"
    echo "Mapping rows to create    : 0"
    echo

    # The child gate owns the exact-DLL backup, CommunityServer-only restart,
    # MySQL guards, DB invariants and its own mutation rollback.
    if ! bash "$BASE" install; then
        # If its internal rollback happened after a MEGAcmd probe, make sure
        # no detached per-slot test server survives with removed runtime files.
        stop_target_megacmd
        fail "base live stage-1 installer failed (its rollback path was invoked)"
    fi

    rollback_on_error(){
        local rc=$?
        trap - ERR
        echo "BRIMSTONE ERROR during WebStudio-identity postcheck — rolling stage 1 back" >&2
        stop_target_megacmd
        if [[ -s "$STATE" ]]; then
            bash "$BASE" rollback || true
        fi
        exit "$rc"
    }
    trap rollback_on_error ERR

    secure_state_for_runtime "$ug"
    runtime_resume_test "$ug"

    # The MEGAcmd server now belongs to the actual WebStudio runtime identity;
    # leave it available for the upcoming one-provider live browse test.
    printf 'runtime_uid_gid=%s\n' "$ug" >> "$STATE"
    chmod 600 "$STATE"

    trap - ERR

    echo
    echo "============================================================"
    echo " PASS — v0.002cc LIVE STAGE 1 WEBSTUDIO RUNTIME PROVEN"
    echo "============================================================"
    echo "WebStudio UID:GID : $ug"
    echo "Target HOME       : $TARGET_HOME"
    echo "Target HOME mode  : $(docker exec "$C" stat -c '%a' "$TARGET_HOME")"
    echo "Target HOME owner : $(docker exec "$C" stat -c '%u:%g' "$TARGET_HOME")"
    echo "Provider rows     : 0"
    echo "Mapping rows      : 0"
    echo "Next              : create ONE controlled BrimstoneMegaCloud provider row and browse in real tenant context"
}

status(){
    bash "$BASE" status
    if docker exec "$C" test -e "$TARGET_HOME" >/dev/null 2>&1; then
        echo "Runtime HOME owner: $(docker exec "$C" stat -c '%u:%g' "$TARGET_HOME")"
        echo "Runtime HOME mode : $(docker exec "$C" stat -c '%a' "$TARGET_HOME")"
    fi
    if [[ -s "$STATE" ]]; then
        sed -n 's/^runtime_uid_gid=/WebStudio UID:GID: /p' "$STATE"
    fi
}

rollback(){
    [[ -s "$STATE" ]] || fail "no v0.002cc live deployment state file"
    stop_target_megacmd
    bash "$BASE" rollback
}

case "$MODE" in
    install) install ;;
    status) status ;;
    rollback) rollback ;;
    *) echo "Usage: $0 {install|status|rollback}" >&2; exit 2 ;;
esac
