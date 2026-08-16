#!/usr/bin/env bash
set -euo pipefail

DEV="${DEV:-/opt/communityserver-megas4-dev}"
IMAGE="${IMAGE:-onlyoffice/communityserver:12.8.0.1971}"
LIVE_CONTAINER="${LIVE_CONTAINER:-onlyoffice-community-server}"
CACHE="${CACHE:-/opt/megas4-nuget-cache}"

EXPECTED_SOURCE_COMMIT="fe1fa7babd093969e939ba6ff45a9fee1299dc93"
EXPECTED_STOCK_DLL_HASH="0b7188ab9b94ee886814c96de7b678395596421cb46df6a9e541767aab01c89d"

DIR="$DEV/module/ASC.Files.Thirdparty"
ORIG="$DIR/ASC.Files.Thirdparty.csproj"
BUILD="$DIR/ASC.Files.Thirdparty.MegaS4.Linux.csproj"
BIN="$DEV/web/studio/ASC.Web.Studio/bin"
NEW="$BIN/ASC.Files.Thirdparty.dll"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
    echo "FAIL - $*" >&2
    exit 1
}

cleanup() {
    rm -f "$BUILD"
}
trap cleanup EXIT

echo "============================================================"
echo " MEGA S4 - COMMUNITYSERVER 12.8 LINUX BUILD"
echo "============================================================"

test -d "$DEV/.git" || fail "CommunityServer source tree not found: $DEV"
HEAD="$(git -C "$DEV" rev-parse HEAD)"
[[ "$HEAD" == "$EXPECTED_SOURCE_COMMIT" ]] || fail "source baseline mismatch: $HEAD"

docker inspect "$LIVE_CONTAINER" >/dev/null 2>&1 || fail "live container not found: $LIVE_CONTAINER"
LIVE_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$LIVE_CONTAINER")"
[[ "$LIVE_IMAGE" == "$IMAGE" ]] || fail "live image mismatch: expected $IMAGE, got $LIVE_IMAGE"

for marker in \
    'ProviderTypes.MegaS4' \
    'MegaS4ProviderInfo' \
    'MegaS4DaoSelector'; do
    grep -Rqs "$marker" \
        "$DIR/ProviderAccountDao.cs" \
        "$DIR/ProviderDao/ProviderDaoBase.cs" \
        "$ORIG" \
        || fail "MEGA S4 integration marker missing: $marker"
done

for source in \
    MegaS4Auth.cs MegaS4DaoBase.cs MegaS4DaoSelector.cs MegaS4Entry.cs \
    MegaS4FileDao.cs MegaS4FolderDao.cs MegaS4Id.cs MegaS4Options.cs \
    MegaS4ProviderInfo.cs MegaS4SecurityDao.cs MegaS4Storage.cs MegaS4TagDao.cs; do
    test -s "$DIR/MegaS4/$source" || fail "MEGA S4 source missing: $source"
done

echo
echo "=== STAGE EXACT LIVE WEBSTUDIO BINARIES ==="
rm -rf "$BIN"
mkdir -p "$BIN"
docker cp "$LIVE_CONTAINER:/var/www/onlyoffice/WebStudio/bin/." "$BIN/" >/dev/null

LIVE_HASH="$(docker exec "$LIVE_CONTAINER" sha256sum /var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll | awk '{print $1}')"
STAGED_HASH="$(sha256sum "$BIN/ASC.Files.Thirdparty.dll" | awk '{print $1}')"
[[ "$LIVE_HASH" == "$EXPECTED_STOCK_DLL_HASH" ]] || fail "live stock DLL hash mismatch: $LIVE_HASH"
[[ "$STAGED_HASH" == "$LIVE_HASH" ]] || fail "staged baseline does not match live DLL"
echo "PASS - stock DLL baseline: $LIVE_HASH"

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
    raise SystemExit("Microsoft.CSharp.targets marker not found")
if "Microsoft.NETFramework.ReferenceAssemblies.net48" in text:
    raise SystemExit("reference-pack injection unexpectedly already present")
text = text.replace(marker, addition + "\n" + marker, 1)
open(dst, "w", encoding="utf-8").write(text)
PY

rm -rf "$DIR/obj"
mkdir -p "$CACHE"

echo
echo "=== RESTORE + BUILD IN ONE COMMUNITYSERVER CONTAINER ==="
docker run --rm \
    --name megas4-build \
    --entrypoint /bin/bash \
    -v "$DEV:/src" \
    -v "$CACHE:/root/.nuget/packages" \
    -w /src \
    "$IMAGE" \
    -lc '
        set -euo pipefail
        PROJECT=module/ASC.Files.Thirdparty/ASC.Files.Thirdparty.MegaS4.Linux.csproj

        msbuild "$PROJECT" \
          /t:Restore \
          /p:RestoreIgnoreFailedSources=true \
          /v:minimal

        REF=/root/.nuget/packages/microsoft.netframework.referenceassemblies.net48/1.0.3/build/.NETFramework/v4.8/System.Net.Http.dll
        test -s "$REF"
        monodis --assembly "$REF" | grep -q "Version:       4.2.0.0"
        echo "PASS - Microsoft net48 System.Net.Http 4.2.0.0 reference pack"

        msbuild "$PROJECT" \
          /t:Build \
          /p:Configuration=Release \
          /p:Platform=AnyCPU \
          /p:BuildProjectReferences=false \
          /p:RestoreIgnoreFailedSources=true \
          /v:minimal
    '

test -s "$NEW" || fail "build did not produce $NEW"

echo
echo "=== CLR VALIDATION ==="
EXPECTED_LIVE_STOCK_HASH="$EXPECTED_STOCK_DLL_HASH" \
LIVE_CONTAINER="$LIVE_CONTAINER" \
IMAGE="$IMAGE" \
"$SCRIPT_DIR/verify-mega-s4-dll.sh" "$NEW"

echo
echo "============================================================"
echo " PASS - MEGA S4 DLL BUILT AND VALIDATED"
echo "============================================================"
echo "Candidate: $NEW"
sha256sum "$NEW"
echo "No live ONLYOFFICE file was modified."
