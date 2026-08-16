#!/usr/bin/env bash
set -Eeuo pipefail

# BRIMSTONE CUSTOM CODE — MEGA S4 v4 rebuild gate.
REPO="${REPO:-/opt/mega-cloud-connectors-for-onlyoffice}"
DEV="${DEV:-/opt/communityserver-megas4-dev}"
IMAGE="${IMAGE:-onlyoffice/communityserver:12.8.0.1971}"
LIVE_CONTAINER="${LIVE_CONTAINER:-onlyoffice-community-server}"
DB_CONTAINER="${DB_CONTAINER:-onlyoffice-mysql-server}"
CACHE="${CACHE:-/opt/megas4-nuget-cache}"

UPSTREAM_COMMIT="fe1fa7babd093969e939ba6ff45a9fee1299dc93"
EXPECTED_LIVE_DLL_HASH="3540c74cde53997e680846bd05c86eedbb678d544f16f56de5fbe916393037f2"

DIR="$DEV/module/ASC.Files.Thirdparty"
ORIG="$DIR/ASC.Files.Thirdparty.csproj"
BUILD="$DIR/ASC.Files.Thirdparty.BrimstoneMegaS4V4.Linux.csproj"
BIN="$DEV/web/studio/ASC.Web.Studio/bin"
NEW="$BIN/ASC.Files.Thirdparty.dll"
SRC="$REPO/src/mega-s4/communityserver-12.8/MegaS4"
PATCHER="$REPO/scripts/patch-communityserver-12.8-mega-s4-v4.py"
VERIFY="$REPO/scripts/verify-mega-s4-dll.sh"

fail(){ echo "FAIL - $*" >&2; exit 1; }
cleanup(){ rm -f "$BUILD"; }
trap cleanup EXIT

banner(){
  echo "============================================================"
  echo " BRIMSTONE MEGA S4 v4 - REBUILD GATE"
  echo "============================================================"
}

banner

test -d "$REPO/.git" || fail "connector checkout not found: $REPO"
[[ -z "$(git -C "$REPO" status --porcelain)" ]] || fail "connector worktree is not clean"

grep -Fq 'BRIMSTONE CUSTOM CODE' "$SRC/BrimstoneMegaS4Secrets.cs" || fail "Brimstone secret bridge missing"
grep -Fq 'BRIMSTONE CUSTOM CODE' "$SRC/BrimstoneMegaS4Handler.cs" || fail "Brimstone handler missing"
grep -Fq 'BRIMSTONE:S3COMPATIBLE:IMPORT' "$SRC/BrimstoneMegaS4Secrets.cs" || fail "shared import sentinel missing"
grep -Fq 'private const string Prefix = "sbox-megas4-";' "$SRC/MegaS4Id.cs" || fail "mapping-safe prefix missing"
grep -Fq 'return text ?? string.Empty;' "$SRC/MegaS4DaoBase.cs" || fail "tolerant provider-native ID handling missing"
test -s "$PATCHER" || fail "v4 patcher missing"
test -s "$VERIFY" || fail "DLL verifier missing"
echo "PASS - reviewed BRIMSTONE v4 source present"

test -d "$DEV/.git" || fail "CommunityServer source tree not found: $DEV"
[[ "$(git -C "$DEV" rev-parse HEAD)" == "$UPSTREAM_COMMIT" ]] || fail "CommunityServer baseline mismatch"

docker inspect "$LIVE_CONTAINER" >/dev/null 2>&1 || fail "live CommunityServer missing"
[[ "$(docker inspect -f '{{.State.Running}}' "$LIVE_CONTAINER")" == "true" ]] || fail "live CommunityServer not running"
[[ "$(docker inspect -f '{{.Config.Image}}' "$LIVE_CONTAINER")" == "$IMAGE" ]] || fail "live image mismatch"

LIVE_HASH="$(docker exec "$LIVE_CONTAINER" sha256sum /var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll | awk '{print $1}')"
[[ "$LIVE_HASH" == "$EXPECTED_LIVE_DLL_HASH" ]] || fail "live DLL is not expected provider-contract build: $LIVE_HASH"
echo "PASS - expected provider-contract live DLL: $LIVE_HASH"

MEGA_ROWS="$(docker exec "$DB_CONTAINER" sh -lc 'mysql --batch --raw --skip-column-names -uroot -p"$MYSQL_ROOT_PASSWORD" onlyoffice -e "SELECT COUNT(*) FROM files_thirdparty_account WHERE LOWER(provider)=\"megas4\";"' 2>/dev/null)"
[[ "$MEGA_ROWS" == "0" ]] || fail "MegaS4 account rows exist: $MEGA_ROWS"
echo "PASS - no MegaS4 account rows before rebuild"

echo
echo "=== RESET ONLY PATCHED THIRD-PARTY BUILD FILES TO EXACT UPSTREAM ==="
git -C "$DEV" checkout "$UPSTREAM_COMMIT" -- \
  module/ASC.Files.Thirdparty/ProviderAccountDao.cs \
  module/ASC.Files.Thirdparty/ProviderDao/ProviderDaoBase.cs \
  module/ASC.Files.Thirdparty/ASC.Files.Thirdparty.csproj
rm -rf "$DIR/MegaS4"
mkdir -p "$DIR/MegaS4"
cp -a "$SRC"/*.cs "$DIR/MegaS4/"
python3 "$PATCHER" "$DEV"
echo "PASS - exact upstream third-party project rebuilt with BRIMSTONE v4 patch"

echo
echo "=== STAGE CURRENT LIVE WEBSTUDIO BINARIES AS REFERENCES ==="
rm -rf "$BIN"
mkdir -p "$BIN"
docker cp "$LIVE_CONTAINER:/var/www/onlyoffice/WebStudio/bin/." "$BIN/" >/dev/null
[[ "$(sha256sum "$BIN/ASC.Files.Thirdparty.dll" | awk '{print $1}')" == "$LIVE_HASH" ]] || fail "staged live DLL mismatch"
echo "PASS - current runtime references staged"

echo
echo "=== CREATE TEMPORARY NET48 BUILD PROJECT ==="
python3 - "$ORIG" "$BUILD" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, "r", encoding="utf-8-sig").read()
marker = '  <Import Project="$(MSBuildToolsPath)\\Microsoft.CSharp.targets" />'
addition = r'''  <ItemGroup>
    <PackageReference Include="Microsoft.NETFramework.ReferenceAssemblies.net48">
      <Version>1.0.3</Version>
      <PrivateAssets>all</PrivateAssets>
      <IncludeAssets>runtime; build; native; contentfiles; analyzers</IncludeAssets>
    </PackageReference>
  </ItemGroup>
'''
if marker not in text:
    raise SystemExit("FAIL - Microsoft.CSharp.targets marker not found")
if "Microsoft.NETFramework.ReferenceAssemblies.net48" in text:
    raise SystemExit("FAIL - net48 reference pack already injected")
text = text.replace(marker, addition + "\n" + marker, 1)
open(dst, "w", encoding="utf-8").write(text)
PY

rm -rf "$DIR/obj"
mkdir -p "$CACHE"

echo
echo "=== RESTORE + BUILD ==="
docker run --rm \
  --name brimstone-megas4-v4-build \
  --entrypoint /bin/bash \
  -v "$DEV:/src" \
  -v "$CACHE:/root/.nuget/packages" \
  -w /src \
  "$IMAGE" \
  -lc '
    set -euo pipefail
    PROJECT=module/ASC.Files.Thirdparty/ASC.Files.Thirdparty.BrimstoneMegaS4V4.Linux.csproj
    msbuild "$PROJECT" /t:Restore /p:RestoreIgnoreFailedSources=true /v:minimal
    REF=/root/.nuget/packages/microsoft.netframework.referenceassemblies.net48/1.0.3/build/.NETFramework/v4.8/System.Net.Http.dll
    test -s "$REF"
    monodis --assembly "$REF" | grep -q "Version:       4.2.0.0"
    msbuild "$PROJECT" /t:Build /p:Configuration=Release /p:Platform=AnyCPU /p:BuildProjectReferences=false /p:RestoreIgnoreFailedSources=true /v:minimal
  '

test -s "$NEW" || fail "build did not produce candidate DLL"
NEW_HASH="$(sha256sum "$NEW" | awk '{print $1}')"
[[ "$NEW_HASH" != "$LIVE_HASH" ]] || fail "candidate is identical to current live DLL"

echo
echo "=== CLR / BRIMSTONE VALIDATION ==="
EXPECTED_LIVE_STOCK_HASH="$EXPECTED_LIVE_DLL_HASH" \
LIVE_CONTAINER="$LIVE_CONTAINER" \
IMAGE="$IMAGE" \
bash "$VERIFY" "$NEW"

docker run --rm --entrypoint /bin/bash -v "$BIN:/candidate:ro" "$IMAGE" -s <<'CHECK'
set -euo pipefail
DLL=/candidate/ASC.Files.Thirdparty.dll
TYPES="$(monodis --typedef "$DLL")"
printf '%s\n' "$TYPES" | grep -Fq 'ASC.Files.Thirdparty.MegaS4.BrimstoneMegaS4Secrets'
printf '%s\n' "$TYPES" | grep -Fq 'ASC.Files.Thirdparty.MegaS4.BrimstoneMegaS4Handler'
monodis --userstrings "$DLL" | grep -Fq 'BRIMSTONE:S3COMPATIBLE:IMPORT'
monodis --userstrings "$DLL" | grep -Fq 'sbox-megas4-'
echo 'PASS - Brimstone secret bridge type'
echo 'PASS - Brimstone bucket handler type'
echo 'PASS - Brimstone import sentinel embedded'
echo 'PASS - mapping-safe provider prefix embedded'
CHECK

echo
echo "============================================================"
echo " PASS - BRIMSTONE MEGA S4 v4 DLL BUILT AND VALIDATED"
echo "============================================================"
echo "Candidate: $NEW"
echo "SHA256   : $NEW_HASH"
echo "Live DLL : $LIVE_HASH"
echo "LIVE ONLYOFFICE WAS NOT MODIFIED."
