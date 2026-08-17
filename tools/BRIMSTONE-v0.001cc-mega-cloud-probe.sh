#!/usr/bin/env bash
# BRIMSTONE CUSTOM CODE.
# Build and exercise the native MEGA Cloud v0.001cc probe in a disposable
# container made from the exact ONLYOFFICE CommunityServer image. Nothing in
# this script modifies or restarts the live ONLYOFFICE containers.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/src/mega-cloud/native/BRIMSTONE-SDK-MANIFEST.env"
BUILD_ROOT="$ROOT/build/mega-cloud-v0.001cc"
SDK_SRC="$BUILD_ROOT/mega-sdk"
VCPKG_SRC="$BUILD_ROOT/vcpkg"
SDK_BUILD="$BUILD_ROOT/sdk-build"
SDK_PREFIX="$BUILD_ROOT/sdk-prefix"
PROBE_BUILD="$BUILD_ROOT/probe-build"
STATE_DIR="$BUILD_ROOT/state"
PROBE_BIN="$PROBE_BUILD/brimstone-mega-cloud-probe"
BUILDER_IMAGE="onlyoffice/communityserver:12.8.0.1971"
EXPECTED_BRANCH="v0.001cc-mega-cloud"

[[ -f "$MANIFEST" ]] || { echo "Missing $MANIFEST" >&2; exit 2; }
# shellcheck source=/dev/null
source "$MANIFEST"

fail() { echo "BRIMSTONE FAIL: $*" >&2; exit 1; }
info() { echo "BRIMSTONE: $*"; }

require_host() {
    command -v git >/dev/null 2>&1 || fail "git is required on the host"
    command -v docker >/dev/null 2>&1 || fail "docker is required on the host"

    [[ "$(git -C "$ROOT" branch --show-current)" == "$EXPECTED_BRANCH" ]] ||
        fail "expected branch $EXPECTED_BRANCH, found $(git -C "$ROOT" branch --show-current)"

    [[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]] ||
        fail "repository is dirty; commit/stash changes before the exact v0.001cc build"

    docker image inspect "$BUILDER_IMAGE" >/dev/null 2>&1 ||
        fail "required builder image is not local: $BUILDER_IMAGE"
}

preflight() {
    require_host
    echo "=== BRIMSTONE MEGA CLOUD v0.001cc PREFLIGHT ==="
    echo "repo:          $ROOT"
    echo "branch:        $(git -C "$ROOT" branch --show-current)"
    echo "head:          $(git -C "$ROOT" rev-parse HEAD)"
    echo "builder image: $BUILDER_IMAGE"
    echo "MEGA SDK tag:  v$BRIMSTONE_MEGA_SDK_VERSION"
    echo "MEGA SDK SHA:  $BRIMSTONE_MEGA_SDK_COMMIT"
    echo "vcpkg SHA:     $BRIMSTONE_VCPKG_BASELINE"
    echo "live stack:    NOT TOUCHED"
}

build_probe() {
    preflight
    mkdir -p "$BUILD_ROOT"

    info "building in disposable $BUILDER_IMAGE container; first vcpkg build can take a while"

    docker run --rm \
        --entrypoint /bin/bash \
        -v "$ROOT:/work" \
        -e BRIMSTONE_MEGA_SDK_VERSION \
        -e BRIMSTONE_MEGA_SDK_COMMIT \
        -e BRIMSTONE_VCPKG_BASELINE \
        "$BUILDER_IMAGE" -lc '
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    build-essential ca-certificates cmake curl git ninja-build pkg-config python3 \
    zip unzip autoconf autoconf-archive automake nasm libtool libtool-bin

BUILD_ROOT=/work/build/mega-cloud-v0.001cc
SDK_SRC=$BUILD_ROOT/mega-sdk
VCPKG_SRC=$BUILD_ROOT/vcpkg
SDK_BUILD=$BUILD_ROOT/sdk-build
SDK_PREFIX=$BUILD_ROOT/sdk-prefix
PROBE_BUILD=$BUILD_ROOT/probe-build

fetch_exact() {
    local url=$1 dir=$2 sha=$3
    if [[ ! -d $dir/.git ]]; then
        rm -rf "$dir"
        mkdir -p "$dir"
        git -C "$dir" init -q
        git -C "$dir" remote add origin "$url"
        git -C "$dir" fetch -q --depth 1 origin "$sha"
        git -C "$dir" checkout -q --detach FETCH_HEAD
    fi
    local got
    got=$(git -C "$dir" rev-parse HEAD)
    [[ $got == "$sha" ]] || {
        echo "BRIMSTONE FAIL: $dir is at $got, expected $sha; run clean-build" >&2
        exit 1
    }
}

fetch_exact https://github.com/meganz/sdk.git "$SDK_SRC" "$BRIMSTONE_MEGA_SDK_COMMIT"
fetch_exact https://github.com/microsoft/vcpkg.git "$VCPKG_SRC" "$BRIMSTONE_VCPKG_BASELINE"

"$VCPKG_SRC/bootstrap-vcpkg.sh" -disableMetrics

cmake -G Ninja -S "$SDK_SRC" -B "$SDK_BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$SDK_PREFIX" \
    -DVCPKG_ROOT="$VCPKG_SRC" \
    -DBUILD_SHARED_LIBS=OFF \
    -DENABLE_SDKLIB_EXAMPLES=OFF \
    -DENABLE_SDKLIB_TESTS=OFF \
    -DENABLE_SDKLIB_WERROR=OFF \
    -DENABLE_SYNC=OFF \
    -DENABLE_CHAT=OFF \
    -DENABLE_MEDIA_FILE_METADATA=OFF \
    -DENABLE_DRIVE_NOTIFICATIONS=OFF \
    -DENABLE_QT_BINDINGS=OFF \
    -DENABLE_JAVA_BINDINGS=OFF \
    -DENABLE_ISOLATED_GFX=OFF \
    -DUSE_FREEIMAGE=OFF \
    -DUSE_FFMPEG=OFF \
    -DUSE_LIBUV=OFF \
    -DUSE_PDFIUM=OFF \
    -DUSE_READLINE=OFF

cmake --build "$SDK_BUILD" --target SDKlib -j"$(nproc)"
cmake --install "$SDK_BUILD"

cmake -G Ninja -S /work/src/mega-cloud/native -B "$PROBE_BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$SDK_PREFIX"
cmake --build "$PROBE_BUILD" --target BrimstoneMegaCloudProbe -j"$(nproc)"

BIN="$PROBE_BUILD/brimstone-mega-cloud-probe"
[[ -x $BIN ]]
echo
echo "=== BRIMSTONE PROBE BUILT ==="
sha256sum "$BIN"
ldd "$BIN" || true
'

    [[ -x "$PROBE_BIN" ]] || fail "build completed without $PROBE_BIN"
    info "probe ready: $PROBE_BIN"
}

status() {
    require_host
    echo "=== BRIMSTONE MEGA CLOUD v0.001cc STATUS ==="
    echo "branch: $(git -C "$ROOT" branch --show-current)"
    echo "head:   $(git -C "$ROOT" rev-parse HEAD)"
    if [[ -x "$PROBE_BIN" ]]; then
        echo "probe:  BUILT"
        sha256sum "$PROBE_BIN"
    else
        echo "probe:  not built"
    fi
    if [[ -f "$STATE_DIR/session" ]]; then
        echo "session test file: present ($(stat -c %a "$STATE_DIR/session" 2>/dev/null || echo '?') permissions)"
    else
        echo "session test file: absent"
    fi
    echo "live stack: NOT TOUCHED"
}

ensure_probe() {
    require_host
    [[ -x "$PROBE_BIN" ]] || fail "probe is not built; run: $0 build"
    mkdir -p "$STATE_DIR/cache"
    chmod 700 "$STATE_DIR" "$STATE_DIR/cache"
}

run_probe_container() {
    local mode=$1
    docker run --rm \
        --entrypoint /bin/bash \
        -v "$ROOT:/work" \
        -e BRIMSTONE_MEGA_APP_KEY \
        -e BRIMSTONE_MEGA_EMAIL \
        -e BRIMSTONE_MEGA_PASSWORD \
        -e BRIMSTONE_MEGA_MFA \
        -e BRIMSTONE_MEGA_USER_AGENT \
        "$BUILDER_IMAGE" -lc "
export LD_LIBRARY_PATH=/work/build/mega-cloud-v0.001cc/sdk-prefix/lib:/work/build/mega-cloud-v0.001cc/sdk-prefix/lib64:\${LD_LIBRARY_PATH:-}
export BRIMSTONE_MEGA_CACHE_DIR=/work/build/mega-cloud-v0.001cc/state/cache
export BRIMSTONE_MEGA_SESSION_FILE=/work/build/mega-cloud-v0.001cc/state/session
exec /work/build/mega-cloud-v0.001cc/probe-build/brimstone-mega-cloud-probe $mode
"
}

auth_root() {
    ensure_probe

    local appkey email password mfa output rc
    read -r -p "MEGA application key: " appkey
    read -r -p "MEGA account email: " email
    read -r -s -p "MEGA account password: " password
    echo

    export BRIMSTONE_MEGA_APP_KEY="$appkey"
    export BRIMSTONE_MEGA_EMAIL="$email"
    export BRIMSTONE_MEGA_PASSWORD="$password"
    export BRIMSTONE_MEGA_MFA=""
    export BRIMSTONE_MEGA_USER_AGENT

    if output=$(run_probe_container auth-root); then
        rc=0
    else
        rc=$?
    fi
    echo "$output"

    if [[ $rc -eq 26 ]] || grep -q '"symbol":"MFA_REQUIRED"' <<<"$output"; then
        read -r -p "MEGA MFA code: " mfa
        export BRIMSTONE_MEGA_MFA="$mfa"
        if output=$(run_probe_container auth-root); then
            rc=0
        else
            rc=$?
        fi
        echo "$output"
    fi

    unset BRIMSTONE_MEGA_APP_KEY BRIMSTONE_MEGA_EMAIL BRIMSTONE_MEGA_PASSWORD BRIMSTONE_MEGA_MFA
    unset appkey email password mfa
    return "$rc"
}

resume_root() {
    ensure_probe
    [[ -s "$STATE_DIR/session" ]] || fail "no saved test session; run auth-root first"

    local appkey output rc
    read -r -p "MEGA application key: " appkey
    export BRIMSTONE_MEGA_APP_KEY="$appkey"
    export BRIMSTONE_MEGA_EMAIL=""
    export BRIMSTONE_MEGA_PASSWORD=""
    export BRIMSTONE_MEGA_MFA=""
    export BRIMSTONE_MEGA_USER_AGENT

    if output=$(run_probe_container resume-root); then
        rc=0
    else
        rc=$?
    fi
    echo "$output"
    unset BRIMSTONE_MEGA_APP_KEY
    unset appkey
    return "$rc"
}

clean_state() {
    require_host
    rm -rf "$STATE_DIR"
    info "removed only the disposable Brimstone MEGA test session/cache"
}

clean_build() {
    require_host
    rm -rf "$BUILD_ROOT"
    info "removed only $BUILD_ROOT"
}

case "${1:-status}" in
    preflight) preflight ;;
    build) build_probe ;;
    status) status ;;
    auth-root) auth_root ;;
    resume-root) resume_root ;;
    clean-state) clean_state ;;
    clean-build) clean_build ;;
    *)
        echo "Usage: $0 {preflight|build|status|auth-root|resume-root|clean-state|clean-build}" >&2
        exit 2
        ;;
esac
