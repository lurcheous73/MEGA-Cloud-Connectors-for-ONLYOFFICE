#!/usr/bin/env bash
# BRIMSTONE CUSTOM CODE.
# v0.002cc read-only browse contract probe for normal MEGA Cloud.
# Uses the accepted v0.001cc official MEGAcmd engine/session state and emits
# MEGA node handles plus stable long-list metadata for a remote folder.
# This script does not modify or restart the live ONLYOFFICE stack.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="$ROOT/build/mega-cloud-v0.001cc"
MEGACMD_PREFIX="$BUILD_ROOT/megacmd-prefix"
STATE_ROOT="$BUILD_ROOT/megacmd-state"
BUILDER_IMAGE="onlyoffice/communityserver:12.8.0.1971"
EXPECTED_BRANCH="v0.002cc-mega-cloud"

fail() { echo "BRIMSTONE FAIL: $*" >&2; exit 1; }

validate_slot() {
    local slot=${1:-test1}
    [[ "$slot" =~ ^[A-Za-z0-9_-]{1,32}$ ]] ||
        fail "slot must contain only letters, digits, underscore or hyphen (max 32 chars)"
    printf %s "$slot"
}

require_host() {
    command -v git >/dev/null 2>&1 || fail "git is required on the host"
    command -v docker >/dev/null 2>&1 || fail "docker is required on the host"

    local branch
    branch="$(git -C "$ROOT" branch --show-current)"
    [[ "$branch" == "$EXPECTED_BRANCH" ]] ||
        fail "expected branch $EXPECTED_BRANCH, found $branch"

    [[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]] ||
        fail "repository is dirty; commit/stash changes before the exact v0.002cc probe"

    docker image inspect "$BUILDER_IMAGE" >/dev/null 2>&1 ||
        fail "required builder image is not local: $BUILDER_IMAGE"

    [[ -x "$MEGACMD_PREFIX/usr/bin/mega-ls" ]] ||
        fail "accepted MEGAcmd engine is missing; v0.001cc build must remain available locally"
}

main() {
    require_host

    local slot remote state socket session
    slot=$(validate_slot "${1:-test1}")
    remote=${2:-/}
    state="$STATE_ROOT/$slot"
    socket="brimstone-${slot}.socket"
    session="$state/home/.megaCmd/session"

    [[ -s "$session" ]] ||
        fail "no saved MEGA session for slot $slot"

    echo "=== BRIMSTONE MEGA CLOUD v0.002cc BROWSE CONTRACT ==="
    echo "branch:     $(git -C "$ROOT" branch --show-current)"
    echo "head:       $(git -C "$ROOT" rev-parse HEAD)"
    echo "slot:       $slot"
    echo "remote:     $remote"
    echo "identity:   MEGA node handles"
    echo "password:   NOT REQUESTED"
    echo "operation:  READ ONLY"
    echo "live stack: NOT TOUCHED"
    echo

    docker run --rm \
        --entrypoint /bin/bash \
        -v "$ROOT:/work" \
        -e HOME="/work/build/mega-cloud-v0.001cc/megacmd-state/$slot/home" \
        -e MEGACMD_SOCKET_NAME="$socket" \
        -e BRIMSTONE_REMOTE_PATH="$remote" \
        "$BUILDER_IMAGE" -lc '
set -Eeuo pipefail
PREFIX=/work/build/mega-cloud-v0.001cc/megacmd-prefix
export PATH="$PREFIX/usr/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/opt/megacmd/lib:${LD_LIBRARY_PATH:-}"

echo "=== BRIMSTONE WHOAMI ==="
timeout 180 "$PREFIX/usr/bin/mega-whoami"

echo
echo "=== BRIMSTONE LS WITH HANDLES ==="
timeout 180 "$PREFIX/usr/bin/mega-ls" -l --show-handles --time-format=ISO6081_WITH_TIME "$BRIMSTONE_REMOTE_PATH"
'
}

main "$@"
