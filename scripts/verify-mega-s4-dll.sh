#!/usr/bin/env bash
set -euo pipefail

DLL="${1:-}"
IMAGE="${IMAGE:-onlyoffice/communityserver:12.8.0.1971}"
LIVE_CONTAINER="${LIVE_CONTAINER:-onlyoffice-community-server}"
EXPECTED_LIVE_STOCK_HASH="${EXPECTED_LIVE_STOCK_HASH:-}"
EXPECTED_CANDIDATE_HASH="${EXPECTED_CANDIDATE_HASH:-}"

fail() {
    echo "FAIL - $*" >&2
    exit 1
}

[[ -n "$DLL" ]] || fail "usage: $0 /path/to/ASC.Files.Thirdparty.dll"
test -s "$DLL" || fail "DLL not found or empty: $DLL"

DLL_DIR="$(cd "$(dirname "$DLL")" && pwd)"
DLL_BASE="$(basename "$DLL")"
CANDIDATE_HASH="$(sha256sum "$DLL" | awk '{print $1}')"

echo "============================================================"
echo " MEGA S4 - CLR DLL VERIFICATION"
echo "============================================================"
echo "Candidate: $DLL"
echo "SHA256   : $CANDIDATE_HASH"

if [[ -n "$EXPECTED_CANDIDATE_HASH" ]]; then
    [[ "$CANDIDATE_HASH" == "$EXPECTED_CANDIDATE_HASH" ]] \
        || fail "candidate hash mismatch"
    echo "PASS - candidate hash matches expected checkpoint"
fi

if docker inspect "$LIVE_CONTAINER" >/dev/null 2>&1; then
    LIVE_HASH="$(docker exec "$LIVE_CONTAINER" sha256sum /var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll | awk '{print $1}')"
    echo "Live stock: $LIVE_HASH"
    [[ "$CANDIDATE_HASH" != "$LIVE_HASH" ]] || fail "candidate DLL is identical to live stock DLL"
    if [[ -n "$EXPECTED_LIVE_STOCK_HASH" ]]; then
        [[ "$LIVE_HASH" == "$EXPECTED_LIVE_STOCK_HASH" ]] \
            || fail "live stock DLL hash mismatch"
    fi
    echo "PASS - candidate differs from live stock DLL"
fi

docker run --rm -i \
    --entrypoint /bin/bash \
    -e DLL_BASE="$DLL_BASE" \
    -v "$DLL_DIR:/candidate:ro" \
    "$IMAGE" -s <<'INNER'
set -euo pipefail
DLL="/candidate/$DLL_BASE"

echo
echo "=== ASSEMBLY ==="
ASM="$(monodis --assembly "$DLL")"
printf "%s\n" "$ASM" | grep -E "^(Name:|Version:)"
printf "%s\n" "$ASM" | grep -q "Name:          ASC.Files.Thirdparty" \
    || { echo "FAIL - wrong assembly name" >&2; exit 1; }

echo
echo "=== REQUIRED MEGA S4 TYPES ==="
TYPES="$(monodis --typedef "$DLL")"
for t in \
    MegaS4Auth \
    MegaS4DaoSelector \
    MegaS4ProviderInfo \
    MegaS4Storage \
    MegaS4FileDao \
    MegaS4FolderDao \
    MegaS4SecurityDao \
    MegaS4TagDao; do
    if printf "%s\n" "$TYPES" | grep -q "ASC.Files.Thirdparty.MegaS4.$t"; then
        echo "PASS - $t"
    else
        echo "FAIL - required CLR type missing: $t" >&2
        exit 1
    fi
done

echo
echo "=== AWS RUNTIME REFERENCES ==="
REFS="$(monodis --assemblyref "$DLL")"
check_ref() {
    local name="$1"
    if printf "%s\n" "$REFS" | awk -v wanted="$name" '
        /^[0-9]+: Version=/ { version=$0 }
        $0 ~ "Name=" wanted { if (version ~ /Version=4\.0\.0\.0/) found=1 }
        END { exit(found ? 0 : 1) }
    '; then
        echo "PASS - $name 4.0.0.0"
    else
        echo "FAIL - $name 4.0.0.0 reference missing" >&2
        exit 1
    fi
}
check_ref AWSSDK.S3
check_ref AWSSDK.Core

echo
echo "PASS - CLR metadata and AWS references validated"
INNER

echo
echo "============================================================"
echo " PASS - MEGA S4 DLL IS DEPLOYABLE"
echo "============================================================"
