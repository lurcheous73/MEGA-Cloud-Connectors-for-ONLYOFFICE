#!/usr/bin/env bash
# BRIMSTONE CUSTOM CODE.
# v0.001cc transport probe for normal MEGA Cloud using unmodified official
# MEGAcmd. User-facing authentication is email/username + password only;
# MFA is handled by MEGA when required and subsequent access resumes from the
# MEGA session held in the isolated HOME for the selected provider slot.
#
# This development script builds/runs only in disposable containers made from
# the exact ONLYOFFICE CommunityServer image. It does not modify or restart the
# live ONLYOFFICE stack.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/src/mega-cloud/native/BRIMSTONE-MEGACMD-MANIFEST.env"
BUILD_ROOT="$ROOT/build/mega-cloud-v0.001cc"
MEGACMD_SRC="$BUILD_ROOT/megacmd-src"
MEGACMD_BUILD="$BUILD_ROOT/megacmd-build"
MEGACMD_PREFIX="$BUILD_ROOT/megacmd-prefix"
VCPKG_SRC="$BUILD_ROOT/vcpkg"
STATE_ROOT="$BUILD_ROOT/megacmd-state"
BUILDER_IMAGE="onlyoffice/communityserver:12.8.0.1971"
EXPECTED_BRANCH="v0.001cc-mega-cloud"

[[ -f "$MANIFEST" ]] || { echo "Missing $MANIFEST" >&2; exit 2; }
# shellcheck source=/dev/null
source "$MANIFEST"
export BRIMSTONE_MEGACMD_VERSION BRIMSTONE_MEGACMD_COMMIT BRIMSTONE_MEGACMD_SDK_COMMIT
export BRIMSTONE_VCPKG_BASELINE BRIMSTONE_CMAKE_VERSION

fail() { echo "BRIMSTONE FAIL: $*" >&2; exit 1; }
info() { echo "BRIMSTONE: $*"; }

require_host() {
    command -v git >/dev/null 2>&1 || fail "git is required on the host"
    command -v docker >/dev/null 2>&1 || fail "docker is required on the host"

    local branch
    branch="$(git -C "$ROOT" branch --show-current)"
    [[ "$branch" == "$EXPECTED_BRANCH" ]] ||
        fail "expected branch $EXPECTED_BRANCH, found $branch"

    [[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]] ||
        fail "repository is dirty; commit/stash changes before the exact v0.001cc test"

    docker image inspect "$BUILDER_IMAGE" >/dev/null 2>&1 ||
        fail "required builder image is not local: $BUILDER_IMAGE"
}

preflight() {
    require_host
    echo "=== BRIMSTONE MEGA CLOUD v0.001cc MEGACMD PREFLIGHT ==="
    echo "repo:             $ROOT"
    echo "branch:           $(git -C "$ROOT" branch --show-current)"
    echo "head:             $(git -C "$ROOT" rev-parse HEAD)"
    echo "builder image:    $BUILDER_IMAGE"
    echo "MEGAcmd version:  $BRIMSTONE_MEGACMD_VERSION"
    echo "MEGAcmd SHA:      $BRIMSTONE_MEGACMD_COMMIT"
    echo "MEGA SDK SHA:     $BRIMSTONE_MEGACMD_SDK_COMMIT"
    echo "vcpkg SHA:        $BRIMSTONE_VCPKG_BASELINE"
    echo "CMake:            $BRIMSTONE_CMAKE_VERSION"
    echo "auth contract:    email/username + password; MFA only if MEGA requests it"
    echo "live stack:       NOT TOUCHED"
}

build_engine() {
    preflight
    mkdir -p "$BUILD_ROOT"

    info "building unmodified official MEGAcmd in disposable $BUILDER_IMAGE container"

    docker run --rm \
        --entrypoint /bin/bash \
        -v "$ROOT:/work" \
        -e BRIMSTONE_MEGACMD_VERSION \
        -e BRIMSTONE_MEGACMD_COMMIT \
        -e BRIMSTONE_MEGACMD_SDK_COMMIT \
        -e BRIMSTONE_VCPKG_BASELINE \
        -e BRIMSTONE_CMAKE_VERSION \
        "$BUILDER_IMAGE" -lc '
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl git ninja-build pkg-config python3 python3-pip \
    zip unzip autoconf autoconf-archive automake nasm libtool libtool-bin

python3 -m pip install --no-cache-dir "cmake==$BRIMSTONE_CMAKE_VERSION"
hash -r
ACTUAL_CMAKE=$(cmake --version | head -n1 | awk "{print \$3}")
[[ "$ACTUAL_CMAKE" == "$BRIMSTONE_CMAKE_VERSION" ]] || {
    echo "BRIMSTONE FAIL: CMake $ACTUAL_CMAKE loaded, expected $BRIMSTONE_CMAKE_VERSION" >&2
    exit 1
}

BUILD_ROOT=/work/build/mega-cloud-v0.001cc
MEGACMD_SRC=$BUILD_ROOT/megacmd-src
MEGACMD_BUILD=$BUILD_ROOT/megacmd-build
MEGACMD_PREFIX=$BUILD_ROOT/megacmd-prefix
VCPKG_SRC=$BUILD_ROOT/vcpkg

fetch_exact() {
    local url=$1 dir=$2 sha=$3
    if [[ ! -d $dir/.git ]]; then
        rm -rf "$dir"
        mkdir -p "$dir"
        git -C "$dir" init -q
        git -C "$dir" remote add origin "$url"
    fi
    git -C "$dir" fetch -q --depth 1 origin "$sha"
    git -C "$dir" reset -q --hard FETCH_HEAD
    local got
    got=$(git -C "$dir" rev-parse HEAD)
    [[ $got == "$sha" ]] || {
        echo "BRIMSTONE FAIL: $dir is at $got, expected $sha" >&2
        exit 1
    }
}

fetch_exact https://github.com/meganz/MEGAcmd.git "$MEGACMD_SRC" "$BRIMSTONE_MEGACMD_COMMIT"

git -C "$MEGACMD_SRC" submodule sync --recursive
git -C "$MEGACMD_SRC" -c protocol.file.allow=always submodule update --init --recursive
ACTUAL_SDK=$(git -C "$MEGACMD_SRC/sdk" rev-parse HEAD)
[[ "$ACTUAL_SDK" == "$BRIMSTONE_MEGACMD_SDK_COMMIT" ]] || {
    echo "BRIMSTONE FAIL: MEGAcmd SDK is $ACTUAL_SDK, expected $BRIMSTONE_MEGACMD_SDK_COMMIT" >&2
    exit 1
}

fetch_exact https://github.com/microsoft/vcpkg.git "$VCPKG_SRC" "$BRIMSTONE_VCPKG_BASELINE"
"$VCPKG_SRC/bootstrap-vcpkg.sh" -disableMetrics

rm -rf "$MEGACMD_PREFIX"

# BRIMSTONE: official MEGAcmd itself compiles against the SDK sync API,
# including MegaSync/MegaSyncStall and sync-aware logout interfaces. Keep that
# API compiled so the pinned upstream MEGAcmd/SDK pair remains compatible.
# Brimstone does not create, configure or run MEGA sync jobs; Connected Cloud
# operations remain direct remote operations through the official MEGA engine.
cmake -G Ninja -S "$MEGACMD_SRC" -B "$MEGACMD_BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$MEGACMD_PREFIX" \
    -DVCPKG_ROOT="$VCPKG_SRC" \
    -DFULL_REQS=OFF \
    -DUSE_PCRE=OFF \
    -DWITH_FUSE=OFF \
    -DENABLE_SYNC=ON \
    -DENABLE_MEGACMD_TESTS=OFF \
    -DENABLE_SDKLIB_TESTS=OFF \
    -DENABLE_SDKLIB_EXAMPLES=OFF \
    -DENABLE_SDKLIB_WERROR=OFF \
    -DENABLE_CHAT=OFF \
    -DENABLE_MEDIA_FILE_METADATA=OFF \
    -DENABLE_DRIVE_NOTIFICATIONS=OFF \
    -DENABLE_ISOLATED_GFX=OFF \
    -DUSE_FREEIMAGE=OFF \
    -DUSE_FFMPEG=OFF \
    -DUSE_LIBUV=OFF \
    -DUSE_PDFIUM=OFF \
    -DUSE_READLINE=ON

cmake --build "$MEGACMD_BUILD" -j"$(nproc)"
cmake --install "$MEGACMD_BUILD"

SERVER="$MEGACMD_PREFIX/usr/bin/mega-cmd-server"
SHELL="$MEGACMD_PREFIX/usr/bin/mega-cmd"
EXEC="$MEGACMD_PREFIX/usr/bin/mega-exec"
[[ -x $SERVER ]] || { echo "BRIMSTONE FAIL: missing $SERVER" >&2; exit 1; }
[[ -x $SHELL ]] || { echo "BRIMSTONE FAIL: missing $SHELL" >&2; exit 1; }
[[ -x $EXEC ]] || { echo "BRIMSTONE FAIL: missing $EXEC" >&2; exit 1; }

echo
echo "=== BRIMSTONE OFFICIAL MEGACMD ENGINE BUILT ==="
echo "MEGAcmd pinned version: $BRIMSTONE_MEGACMD_VERSION"
echo "MEGAcmd commit:         $BRIMSTONE_MEGACMD_COMMIT"
echo "MEGA SDK commit:        $BRIMSTONE_MEGACMD_SDK_COMMIT"
sha256sum "$SERVER" "$SHELL" "$EXEC"
echo
echo "=== BRIMSTONE RUNTIME DEPENDENCIES ==="
ldd "$SERVER" || true
'

    [[ -x "$MEGACMD_PREFIX/usr/bin/mega-cmd-server" ]] ||
        fail "build completed without MEGAcmd server"
    info "official MEGAcmd engine ready under $MEGACMD_PREFIX"
}

status() {
    require_host
    echo "=== BRIMSTONE MEGA CLOUD v0.001cc ENGINE STATUS ==="
    echo "branch: $(git -C "$ROOT" branch --show-current)"
    echo "head:   $(git -C "$ROOT" rev-parse HEAD)"
    if [[ -x "$MEGACMD_PREFIX/usr/bin/mega-cmd-server" ]]; then
        echo "engine: BUILT"
        sha256sum "$MEGACMD_PREFIX/usr/bin/mega-cmd-server"
    else
        echo "engine: not built"
    fi
    echo "state root: $STATE_ROOT"
    echo "live stack: NOT TOUCHED"
}

validate_slot() {
    local slot=${1:-test1}
    [[ "$slot" =~ ^[A-Za-z0-9_-]{1,32}$ ]] ||
        fail "slot must contain only letters, digits, underscore or hyphen (max 32 chars)"
    printf %s "$slot"
}

shell_slot() {
    require_host
    [[ -x "$MEGACMD_PREFIX/usr/bin/mega-cmd" ]] ||
        fail "MEGAcmd engine is not built; run: bash $0 build"

    local slot
    slot=$(validate_slot "${1:-test1}")
    local state="$STATE_ROOT/$slot"
    local socket="brimstone-${slot}.socket"
    mkdir -p "$state/home"
    chmod 700 "$STATE_ROOT" "$state" "$state/home"

    echo "=== BRIMSTONE ISOLATED MEGA CLOUD SHELL ==="
    echo "slot:       $slot"
    echo "HOME:       $state/home"
    echo "socket:     $socket"
    echo "live stack: NOT TOUCHED"
    echo
    echo "First login:  login your-mega-email@example.invalid"
    echo "MEGA will then request the password without an API-key prompt."
    echo "After login:  ls /"
    echo "Exit shell:   quit"
    echo

    docker run --rm -it \
        --entrypoint /bin/bash \
        -v "$ROOT:/work" \
        -e HOME="/work/build/mega-cloud-v0.001cc/megacmd-state/$slot/home" \
        -e MEGACMD_SOCKET_NAME="$socket" \
        "$BUILDER_IMAGE" -lc '
PREFIX=/work/build/mega-cloud-v0.001cc/megacmd-prefix
export PATH="$PREFIX/usr/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/opt/megacmd/lib:${LD_LIBRARY_PATH:-}"
exec "$PREFIX/usr/bin/mega-cmd"
'
}

clean_slot() {
    require_host
    local slot
    slot=$(validate_slot "${1:-test1}")
    rm -rf "$STATE_ROOT/$slot"
    info "removed only disposable MEGA Cloud test state for slot $slot"
}

clean_engine() {
    require_host
    rm -rf "$MEGACMD_SRC" "$MEGACMD_BUILD" "$MEGACMD_PREFIX"
    info "removed only the disposable MEGAcmd source/build/prefix; provider test state retained"
}

case "${1:-status}" in
    preflight) preflight ;;
    build) build_engine ;;
    status) status ;;
    shell) shell_slot "${2:-test1}" ;;
    clean-slot) clean_slot "${2:-test1}" ;;
    clean-engine) clean_engine ;;
    *)
        echo "Usage: $0 {preflight|build|status|shell [slot]|clean-slot [slot]|clean-engine}" >&2
        exit 2
        ;;
esac
