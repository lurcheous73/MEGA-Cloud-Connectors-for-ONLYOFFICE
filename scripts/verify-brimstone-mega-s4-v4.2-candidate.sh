#!/usr/bin/env bash
set -Eeuo pipefail

# BRIMSTONE CUSTOM CODE — verify the already-built v4.2 candidate without rebuilding.
REPO="${REPO:-/opt/mega-cloud-connectors-for-onlyoffice}"
C="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
DB="${MYSQL_CONTAINER:-onlyoffice-mysql-server}"
IMAGE="${IMAGE:-onlyoffice/communityserver:12.8.0.1971}"
CANDIDATE="${MEGA_S4_DLL:-/opt/communityserver-megas4-dev/web/studio/ASC.Web.Studio/bin/ASC.Files.Thirdparty.dll}"
SRC="$REPO/src/mega-s4/communityserver-12.8/MegaS4"

EXPECTED_LIVE_HASH="a5d6698434ef9a18909aa6a2b42657472d832396a918ae648bee2c63255133d2"
EXPECTED_CANDIDATE_HASH="2e5b17bd0e3c7c216428e58e0163c1aacac707cbada4f49edd849daf80cdb787"

fail(){ echo "FAIL - $*" >&2; exit 1; }

mysql_scalar(){
  local sql="$1"
  docker exec -e SQL="$sql" "$DB" sh -lc '
    mysql --batch --raw --skip-column-names -uroot -p"$MYSQL_ROOT_PASSWORD" onlyoffice -e "$SQL"
  ' 2>/dev/null | tr -d '\r'
}

echo "============================================================"
echo " BRIMSTONE MEGA S4 v4.2 — EXISTING CANDIDATE VERIFIER"
echo "============================================================"

[[ -d "$REPO/.git" ]] || fail "connector checkout missing"
[[ -z "$(git -C "$REPO" status --porcelain)" ]] || fail "connector worktree is not clean"

# Verify the source fixes that produced this candidate.
grep -Fq 'DisposableHttpContext rejects null assignments' "$SRC/MegaS4ProviderInfo.cs" || fail "storage invalidation fix marker missing"
! grep -Fq 'DisposableHttpContext.Current[key] = null;' "$SRC/MegaS4ProviderInfo.cs" || fail "illegal null assignment still present in source"
grep -Fq 'ASC.Web.Studio.Global.Authenticate();' "$SRC/BrimstoneMegaS4Handler.cs" || fail "handler auth bootstrap missing in source"
grep -Fq 'BRIMSTONE MEGA S4 handler error:' "$SRC/BrimstoneMegaS4Handler.cs" || fail "handler JSON diagnostic marker missing in source"
echo "PASS - v4.2 source fixes present"

[[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer is not running"
[[ "$(docker inspect -f '{{.State.Running}}' "$DB")" == "true" ]] || fail "MySQL is not running"
LIVE_HASH="$(docker exec "$C" sha256sum /var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll | awk '{print $1}')"
[[ "$LIVE_HASH" == "$EXPECTED_LIVE_HASH" ]] || fail "unexpected live DLL: $LIVE_HASH"
echo "PASS - live remains Brimstone v4: $LIVE_HASH"

[[ "$(mysql_scalar "SELECT COUNT(*) FROM files_thirdparty_account WHERE LOWER(provider)='megas4';")" == "0" ]] || fail "MegaS4 provider rows exist"
[[ "$(mysql_scalar "SELECT COUNT(*) FROM files_thirdparty_id_mapping WHERE id LIKE 'megas4-%' OR hash_id LIKE 'megas4-%';")" == "0" ]] || fail "old MEGA mappings exist"
echo "PASS - database remains clean"

[[ -s "$CANDIDATE" ]] || fail "candidate DLL missing: $CANDIDATE"
CANDIDATE_HASH="$(sha256sum "$CANDIDATE" | awk '{print $1}')"
[[ "$CANDIDATE_HASH" == "$EXPECTED_CANDIDATE_HASH" ]] || fail "candidate hash mismatch: $CANDIDATE_HASH"
echo "PASS - exact existing candidate hash: $CANDIDATE_HASH"

DIR="$(dirname "$CANDIDATE")"
BASE="$(basename "$CANDIDATE")"
docker run --rm -i --entrypoint /bin/bash \
  -e DLL_BASE="$BASE" \
  -v "$DIR:/candidate:ro" \
  "$IMAGE" <<'VERIFY'
set -euo pipefail
DLL="/candidate/$DLL_BASE"

monodis --assembly "$DLL" | grep -q 'Name:          ASC.Files.Thirdparty'
TYPES="$(monodis --typedef "$DLL")"
printf '%s\n' "$TYPES" | grep -Fq 'ASC.Files.Thirdparty.MegaS4.MegaS4ProviderInfo'
printf '%s\n' "$TYPES" | grep -Fq 'ASC.Files.Thirdparty.MegaS4.BrimstoneMegaS4Secrets'
printf '%s\n' "$TYPES" | grep -Fq 'ASC.Files.Thirdparty.MegaS4.BrimstoneMegaS4Handler'

STRINGS="$(monodis --userstrings "$DLL")"
printf '%s\n' "$STRINGS" | grep -Fq 'BRIMSTONE:S3COMPATIBLE:IMPORT'
printf '%s\n' "$STRINGS" | grep -Fq 'sbox-megas4-'
printf '%s\n' "$STRINGS" | grep -Fq 'BRIMSTONE MEGA S4 handler error:'

# The handler bootstrap is executable code, so verify the compiled method reference.
IL="$(mktemp)"
trap 'rm -f "$IL"' EXIT
monodis "$DLL" > "$IL"
grep -Fq 'ASC.Web.Studio.Global::Authenticate' "$IL"

# InvalidateStorage must not assign null to DisposableHttpContext.Item.
# Extract only that method's IL and reject a null followed by set_Item.
python3 - "$IL" <<'PY'
import re, sys
text = open(sys.argv[1], 'r', encoding='utf-8', errors='replace').read()
# Find the method body containing the InvalidateStorage name, then stop at the next method.
pos = text.find('InvalidateStorage')
if pos < 0:
    raise SystemExit('FAIL - InvalidateStorage IL not found')
start = text.rfind('.method', 0, pos)
end = text.find('.method', pos + 1)
body = text[start:end if end >= 0 else len(text)]
if 'DisposableHttpContext::set_Item' in body:
    raise SystemExit('FAIL - InvalidateStorage still calls DisposableHttpContext.set_Item')
print('PASS - compiled InvalidateStorage contains no DisposableHttpContext.set_Item call')
PY

echo 'PASS - required Brimstone v4.2 CLR types/literals present'
echo 'PASS - compiled handler calls ONLYOFFICE Global.Authenticate()'
VERIFY

echo "============================================================"
echo " PASS - BRIMSTONE MEGA S4 v4.2 EXISTING CANDIDATE VERIFIED"
echo "============================================================"
echo "Candidate: $CANDIDATE"
echo "SHA256   : $CANDIDATE_HASH"
echo "Live DLL : $LIVE_HASH"
echo "LIVE ONLYOFFICE WAS NOT MODIFIED."
