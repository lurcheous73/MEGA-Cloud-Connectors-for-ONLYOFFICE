#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${REPO:-/opt/mega-cloud-connectors-for-onlyoffice}"
DEV="${DEV:-/opt/communityserver-megas4-dev}"
IMAGE="${IMAGE:-onlyoffice/communityserver:12.8.0.1971}"
LIVE_CONTAINER="${LIVE_CONTAINER:-onlyoffice-community-server}"
CACHE="${CACHE:-/opt/megas4-nuget-cache}"

UPSTREAM_COMMIT="fe1fa7babd093969e939ba6ff45a9fee1299dc93"
REQUIRED_FIX_COMMIT="69c51f05a1f95fe69c02ac64c286c83f393e54d1"
EXPECTED_LIVE_DLL_HASH="73427e0218d2a19a91cd6e9ceb0f04f137ffba14f6956c754a039474128d0e6a"

DIR="$DEV/module/ASC.Files.Thirdparty"
ORIG="$DIR/ASC.Files.Thirdparty.csproj"
BUILD="$DIR/ASC.Files.Thirdparty.MegaS4.ProviderContract.Linux.csproj"
BIN="$DEV/web/studio/ASC.Web.Studio/bin"
NEW="$BIN/ASC.Files.Thirdparty.dll"
SRC="$REPO/src/mega-s4/communityserver-12.8/MegaS4"
VERIFY="$REPO/scripts/verify-mega-s4-dll.sh"

fail() { echo "FAIL - $*" >&2; exit 1; }
cleanup() { rm -f "$BUILD"; }
trap cleanup EXIT

echo "============================================================"
echo " MEGA S4 - PROVIDER CONTRACT HOTFIX REBUILD"
echo "============================================================"

test -d "$REPO/.git" || fail "connector checkout not found: $REPO"
git -C "$REPO" merge-base --is-ancestor "$REQUIRED_FIX_COMMIT" HEAD \
  || fail "connector checkout does not contain provider-contract fix $REQUIRED_FIX_COMMIT"
[[ -z "$(git -C "$REPO" status --porcelain)" ]] || fail "connector worktree is not clean"

test -d "$DEV/.git" || fail "CommunityServer source tree not found: $DEV"
[[ "$(git -C "$DEV" rev-parse HEAD)" == "$UPSTREAM_COMMIT" ]] || fail "CommunityServer baseline mismatch"

docker inspect "$LIVE_CONTAINER" >/dev/null 2>&1 || fail "live CommunityServer missing"
[[ "$(docker inspect -f '{{.State.Running}}' "$LIVE_CONTAINER")" == "true" ]] || fail "live CommunityServer not running"
[[ "$(docker inspect -f '{{.Config.Image}}' "$LIVE_CONTAINER")" == "$IMAGE" ]] || fail "live image mismatch"

LIVE_HASH="$(docker exec "$LIVE_CONTAINER" sha256sum /var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll | awk '{print $1}')"
[[ "$LIVE_HASH" == "$EXPECTED_LIVE_DLL_HASH" ]] || fail "live DLL is not expected mapping-hotfix build: $LIVE_HASH"
echo "PASS - expected mapping-hotfix live DLL: $LIVE_HASH"

echo
echo "=== VALIDATE REVIEWED PROVIDER CONTRACT FIX ==="
grep -Fq 'private const string Prefix = "sbox-megas4-";' "$SRC/MegaS4Id.cs" || fail "mapping-safe prefix source missing"
grep -Fq 'if (MegaS4Id.TryParse(text, out linkId, out key))' "$SRC/MegaS4DaoBase.cs" || fail "tolerant DecodeId source missing"
grep -Fq 'return text ?? string.Empty;' "$SRC/MegaS4DaoBase.cs" || fail "native-key fallback source missing"
echo "PASS - reviewed provider contract fix present"

echo
echo "=== SYNC MEGA ID + DAO BASE SOURCES INTO DEV TREE ==="
for f in MegaS4Id.cs MegaS4DaoSelector.cs MegaS4DaoBase.cs; do
  install -m 0644 "$SRC/$f" "$DIR/MegaS4/$f"
done
grep -Fq 'sbox-megas4-' "$DIR/MegaS4/MegaS4Id.cs"
grep -Fq 'return text ?? string.Empty;' "$DIR/MegaS4/MegaS4DaoBase.cs"
echo "PASS - dev tree contains provider contract fix"

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
  --name megas4-provider-contract-build \
  --entrypoint /bin/bash \
  -v "$DEV:/src" \
  -v "$CACHE:/root/.nuget/packages" \
  -w /src \
  "$IMAGE" \
  -lc '
    set -euo pipefail
    PROJECT=module/ASC.Files.Thirdparty/ASC.Files.Thirdparty.MegaS4.ProviderContract.Linux.csproj
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
echo "=== CLR VALIDATION ==="
EXPECTED_LIVE_STOCK_HASH="$EXPECTED_LIVE_DLL_HASH" \
LIVE_CONTAINER="$LIVE_CONTAINER" \
IMAGE="$IMAGE" \
bash "$VERIFY" "$NEW"

docker run --rm \
  --entrypoint /bin/bash \
  -v "$BIN:/candidate:ro" \
  "$IMAGE" \
  -lc 'monodis --userstrings /candidate/ASC.Files.Thirdparty.dll | grep -Fq "sbox-megas4-"'

echo
echo "============================================================"
echo " PASS - PROVIDER CONTRACT HOTFIX DLL BUILT AND VALIDATED"
echo "============================================================"
echo "Candidate: $NEW"
echo "SHA256   : $NEW_HASH"
echo "LIVE ONLYOFFICE WAS NOT MODIFIED."
