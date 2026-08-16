#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-/opt/mega-cloud-connectors-for-onlyoffice}"
DEV="${DEV:-/opt/communityserver-megas4-dev}"
IMAGE="${IMAGE:-onlyoffice/communityserver:12.8.0.1971}"
LIVE_CONTAINER="${LIVE_CONTAINER:-onlyoffice-community-server}"
CACHE="${CACHE:-/opt/megas4-nuget-cache}"

UPSTREAM_COMMIT="fe1fa7babd093969e939ba6ff45a9fee1299dc93"
FIX_COMMIT="88c77d7b82c5228e2bea34d95ae9866d8223ec3f"
OLD_LIVE_DLL_HASH="98df3165b21b2011899f17d773f3695437706d01fdcc8e3899303462157acf01"

DIR="$DEV/module/ASC.Files.Thirdparty"
ORIG="$DIR/ASC.Files.Thirdparty.csproj"
BUILD="$DIR/ASC.Files.Thirdparty.MegaS4.MappingFix.Linux.csproj"
BIN="$DEV/web/studio/ASC.Web.Studio/bin"
NEW="$BIN/ASC.Files.Thirdparty.dll"
SRC="$REPO/src/mega-s4/communityserver-12.8/MegaS4"

fail() {
    echo "FAIL - $*" >&2
    exit 1
}

cleanup() {
    rm -f "$BUILD"
}
trap cleanup EXIT

echo "============================================================"
echo " MEGA S4 - NATIVE ID MAPPING HOTFIX REBUILD"
echo "============================================================"

test -d "$REPO/.git" || fail "connector checkout not found: $REPO"
git -C "$REPO" merge-base --is-ancestor "$FIX_COMMIT" HEAD \
    || fail "connector checkout does not contain mapping fix $FIX_COMMIT"

test -d "$DEV/.git" || fail "CommunityServer source tree not found: $DEV"
[[ "$(git -C "$DEV" rev-parse HEAD)" == "$UPSTREAM_COMMIT" ]] \
    || fail "CommunityServer baseline mismatch"

docker inspect "$LIVE_CONTAINER" >/dev/null 2>&1 || fail "live CommunityServer container missing"
[[ "$(docker inspect -f '{{.Config.Image}}' "$LIVE_CONTAINER")" == "$IMAGE" ]] \
    || fail "live image mismatch"

LIVE_HASH="$(docker exec "$LIVE_CONTAINER" sha256sum /var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll | awk '{print $1}')"
[[ "$LIVE_HASH" == "$OLD_LIVE_DLL_HASH" ]] \
    || fail "live DLL is not the expected pre-mapping-fix MEGA build: $LIVE_HASH"
echo "PASS - expected pre-fix live MEGA DLL: $LIVE_HASH"

echo
echo "=== VALIDATE REVIEWED SOURCE FIX ==="
grep -Fq 'private const string Prefix = "sbox-megas4-";' "$SRC/MegaS4Id.cs" \
    || fail "MegaS4Id.cs does not contain native mapping prefix"
grep -Fq '@"^sbox-megas4-\d+' "$SRC/MegaS4DaoSelector.cs" \
    || fail "MegaS4DaoSelector.cs does not contain mapping-safe selector"
echo "PASS - reviewed mapping-safe ID source present"

echo
echo "=== SYNC ONLY ID IMPLEMENTATION INTO DEV TREE ==="
install -m 0644 "$SRC/MegaS4Id.cs" "$DIR/MegaS4/MegaS4Id.cs"
install -m 0644 "$SRC/MegaS4DaoSelector.cs" "$DIR/MegaS4/MegaS4DaoSelector.cs"
grep -Fq 'sbox-megas4-' "$DIR/MegaS4/MegaS4Id.cs"
grep -Fq 'sbox-megas4-' "$DIR/MegaS4/MegaS4DaoSelector.cs"
echo "PASS - dev tree contains mapping fix"

echo
echo "=== STAGE CURRENT LIVE WEBSTUDIO BINARIES AS REFERENCES ==="
rm -rf "$BIN"
mkdir -p "$BIN"
docker cp "$LIVE_CONTAINER:/var/www/onlyoffice/WebStudio/bin/." "$BIN/" >/dev/null
[[ "$(sha256sum "$BIN/ASC.Files.Thirdparty.dll" | awk '{print $1}')" == "$LIVE_HASH" ]] \
    || fail "staged live DLL mismatch"
echo "PASS - live runtime references staged"

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
    --name megas4-mapping-build \
    --entrypoint /bin/bash \
    -v "$DEV:/src" \
    -v "$CACHE:/root/.nuget/packages" \
    -w /src \
    "$IMAGE" \
    -lc '
        set -euo pipefail
        PROJECT=module/ASC.Files.Thirdparty/ASC.Files.Thirdparty.MegaS4.MappingFix.Linux.csproj

        msbuild "$PROJECT" \
          /t:Restore \
          /p:RestoreIgnoreFailedSources=true \
          /v:minimal

        REF=/root/.nuget/packages/microsoft.netframework.referenceassemblies.net48/1.0.3/build/.NETFramework/v4.8/System.Net.Http.dll
        test -s "$REF"
        monodis --assembly "$REF" | grep -q "Version:       4.2.0.0"

        msbuild "$PROJECT" \
          /t:Build \
          /p:Configuration=Release \
          /p:Platform=AnyCPU \
          /p:BuildProjectReferences=false \
          /p:RestoreIgnoreFailedSources=true \
          /v:minimal
    '

test -s "$NEW" || fail "build did not produce candidate DLL"
CANDIDATE_HASH="$(sha256sum "$NEW" | awk '{print $1}')"
[[ "$CANDIDATE_HASH" != "$LIVE_HASH" ]] || fail "candidate is identical to pre-fix live DLL"

echo
echo "=== CLR / PREFIX VALIDATION ==="
docker run --rm \
    --entrypoint /bin/bash \
    -v "$BIN:/candidate:ro" \
    "$IMAGE" \
    -lc '
        set -euo pipefail
        DLL=/candidate/ASC.Files.Thirdparty.dll

        monodis --assembly "$DLL" | grep -q "Name:          ASC.Files.Thirdparty"
        TYPES="$(monodis --typedef "$DLL")"
        for t in MegaS4Auth MegaS4DaoSelector MegaS4ProviderInfo MegaS4Storage MegaS4FileDao MegaS4FolderDao MegaS4SecurityDao MegaS4TagDao; do
            printf "%s\n" "$TYPES" | grep -q "ASC.Files.Thirdparty.MegaS4.$t" \
                || { echo "FAIL - missing CLR type $t" >&2; exit 1; }
        done

        REFS="$(monodis --assemblyref "$DLL")"
        check_ref() {
            local name="$1"
            printf "%s\n" "$REFS" | awk -v wanted="$name" '
                /^[0-9]+: Version=/ { version=$0 }
                $0 ~ "Name=" wanted { if (version ~ /Version=4\.0\.0\.0/) found=1 }
                END { exit(found ? 0 : 1) }
            '
        }
        check_ref AWSSDK.S3 || { echo "FAIL - AWSSDK.S3 4.0.0.0 reference missing" >&2; exit 1; }
        check_ref AWSSDK.Core || { echo "FAIL - AWSSDK.Core 4.0.0.0 reference missing" >&2; exit 1; }

        monodis --userstrings "$DLL" | grep -Fq "sbox-megas4-" \
            || { echo "FAIL - mapping-safe sbox-megas4 prefix absent from CLR user strings" >&2; exit 1; }
        echo "PASS - mapping-safe sbox-megas4 prefix embedded"
    '

echo
echo "============================================================"
echo " PASS - MAPPING HOTFIX DLL BUILT AND VALIDATED"
echo "============================================================"
echo "Candidate: $NEW"
echo "SHA256   : $CANDIDATE_HASH"
echo "LIVE ONLYOFFICE WAS NOT MODIFIED."
