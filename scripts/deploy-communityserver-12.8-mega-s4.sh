#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-status}"
C="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$REPO_ROOT/scripts/install-communityserver-12.8-mega-s4.sh"
CANDIDATE_DLL="${MEGA_S4_DLL:-/opt/communityserver-megas4-dev/web/studio/ASC.Web.Studio/bin/ASC.Files.Thirdparty.dll}"

EXPECTED_REPO_COMMIT="a51eb933a2e895b70a73fdcf81e2e312e27054a1"
EXPECTED_STOCK_DLL="0b7188ab9b94ee886814c96de7b678395596421cb46df6a9e541767aab01c89d"
EXPECTED_MEGA_DLL="98df3165b21b2011899f17d773f3695437706d01fdcc8e3899303462157acf01"
EXPECTED_STOCK_JS="c7bd83aaa28f02676e50b91a30d866e9366ec21565ee6a4f936649be65e50050"
EXPECTED_STOCK_XSL="b16b2e570a47693f1ac0f16112fd562d7ffd0eeef2f80a001e18ea36406fb646"
EXPECTED_STOCK_BUNDLE="1077a3c78a388d1c2a88fddb49d19af4019cebd9a86c7c25e7c82d1e9f555714"

LIVE_ROOT="/var/www/onlyoffice/WebStudio"
LIVE_DLL="$LIVE_ROOT/bin/ASC.Files.Thirdparty.dll"
LIVE_JS="$LIVE_ROOT/Products/Files/Controls/ThirdParty/thirdparty.js"
LIVE_XSL="$LIVE_ROOT/Products/Files/Templates/getthirdpartyitem.xsl"
BUNDLE_DIR="$LIVE_ROOT/App_Data/static/bundle/files/javascript"

fail() { echo "FAIL: $*" >&2; exit 1; }
chash() { docker exec "$C" sha256sum "$1" | awk '{print $1}'; }

find_bundle() {
    mapfile -t BUNDLES < <(docker exec "$C" sh -lc "find '$BUNDLE_DIR' -maxdepth 1 -type f -name 'files-*.js' -print | sort" | tr -d '\r')
    [ "${#BUNDLES[@]}" -eq 1 ] || fail "expected exactly one Files JS bundle, found ${#BUNDLES[@]}"
    printf '%s\n' "${BUNDLES[0]}"
}

exact_preflight() {
    echo "============================================================"
    echo " MEGA S4 — EXACT-HASH LIVE DEPLOYMENT GATE"
    echo "============================================================"

    [ -x "$INSTALLER" ] || fail "installer missing/not executable: $INSTALLER"
    docker inspect "$C" >/dev/null 2>&1 || fail "container $C not found"
    [ "$(docker inspect -f '{{.State.Running}}' "$C")" = "true" ] || fail "$C is not running"

    local head bundle
    head="$(git -C "$REPO_ROOT" rev-parse HEAD)"
    [ "$head" = "$EXPECTED_REPO_COMMIT" ] || fail "repo checkpoint mismatch: expected $EXPECTED_REPO_COMMIT got $head"
    [ -z "$(git -C "$REPO_ROOT" status --porcelain)" ] || fail "connector worktree is not clean"
    echo "PASS: exact Git checkpoint $head"

    [ -s "$CANDIDATE_DLL" ] || fail "candidate DLL missing: $CANDIDATE_DLL"
    [ "$(sha256sum "$CANDIDATE_DLL" | awk '{print $1}')" = "$EXPECTED_MEGA_DLL" ] || fail "candidate MEGA DLL hash mismatch"
    echo "PASS: candidate MEGA DLL hash"

    [ "$(chash "$LIVE_DLL")" = "$EXPECTED_STOCK_DLL" ] || fail "live Thirdparty DLL is not exact stock baseline"
    [ "$(chash "$LIVE_JS")" = "$EXPECTED_STOCK_JS" ] || fail "live thirdparty.js is not exact stock baseline"
    [ "$(chash "$LIVE_XSL")" = "$EXPECTED_STOCK_XSL" ] || fail "live getthirdpartyitem.xsl is not exact stock baseline"
    echo "PASS: exact stock DLL/JS/XSL hashes"

    bundle="$(find_bundle)"
    echo "Bundle: $bundle"
    [ "$(chash "$bundle")" = "$EXPECTED_STOCK_BUNDLE" ] || fail "live Files bundle hash differs from validated baseline"
    echo "PASS: exact stock Files bundle hash"

    echo "============================================================"
    echo " PASS — EXACT LIVE BASELINE CONFIRMED"
    echo "============================================================"
}

case "$MODE" in
    install)
        exact_preflight
        exec "$INSTALLER" install
        ;;
    status)
        exec "$INSTALLER" status
        ;;
    rollback)
        exec "$INSTALLER" rollback
        ;;
    preflight)
        exact_preflight
        ;;
    *)
        echo "Usage: $0 {preflight|install|status|rollback}" >&2
        exit 2
        ;;
esac
