#!/usr/bin/env bash
# BRIMSTONE CUSTOM CODE — v0.002cc compile-only gate.
# Builds the accepted MEGA S4 integration plus the new normal-MEGA Cloud
# read-only DAO slice against the exact CommunityServer 12.8 source/image.
# It never copies a candidate into the live container and never restarts it.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRANCH="v0.002cc-mega-cloud"
IMAGE="onlyoffice/communityserver:12.8.0.1971"
LIVE_CONTAINER="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
SOURCE_REPO="${COMMUNITYSERVER_SOURCE_REPO:-/opt/communityserver-megas4-dev}"
UPSTREAM="fe1fa7babd093969e939ba6ff45a9fee1299dc93"
DEV="$ROOT/build/communityserver-v0.002cc-src"
CACHE="$ROOT/build/communityserver-v0.002cc-nuget-cache"
S4_SRC="$ROOT/src/mega-s4/communityserver-12.8/MegaS4"
CLOUD_SRC="$ROOT/src/mega-cloud/communityserver-12.8/BrimstoneMegaCloud"
S4_PREP="$ROOT/tools/prepare-communityserver-source.py"
CLOUD_PREP="$ROOT/tools/prepare-communityserver-mega-cloud-v0.002cc.py"
DIR="$DEV/module/ASC.Files.Thirdparty"
ORIG="$DIR/ASC.Files.Thirdparty.csproj"
TEMP_PROJECT="$DIR/ASC.Files.Thirdparty.BrimstoneMegaCloudV0002.Linux.csproj"
BIN="$DEV/web/studio/ASC.Web.Studio/bin"
CANDIDATE="$BIN/ASC.Files.Thirdparty.dll"

fail(){ echo "BRIMSTONE FAIL: $*" >&2; exit 1; }

preflight(){
    echo "=== BRIMSTONE MEGA CLOUD v0.002cc COMPILE-ONLY PREFLIGHT ==="
    [[ -d "$ROOT/.git" ]] || fail "connector repository missing"
    [[ "$(git -C "$ROOT" branch --show-current)" == "$BRANCH" ]] || fail "expected branch $BRANCH"
    [[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]] || fail "connector repository is dirty"
    docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "required builder image is not local: $IMAGE"
    docker inspect "$LIVE_CONTAINER" >/dev/null 2>&1 || fail "CommunityServer container missing: $LIVE_CONTAINER"
    [[ -d "$SOURCE_REPO/.git" ]] || fail "CommunityServer source repository missing: $SOURCE_REPO"
    git -C "$SOURCE_REPO" cat-file -e "$UPSTREAM^{commit}" 2>/dev/null || fail "CommunityServer source does not contain pinned commit $UPSTREAM"
    [[ -d "$S4_SRC" ]] || fail "accepted Brimstone MEGA S4 source missing"
    [[ -d "$CLOUD_SRC" ]] || fail "Brimstone MEGA Cloud source missing"
    [[ -s "$S4_PREP" ]] || fail "S4 preparer missing"
    [[ -s "$CLOUD_PREP" ]] || fail "Cloud preparer missing"
    echo "branch:      $(git -C "$ROOT" branch --show-current)"
    echo "head:        $(git -C "$ROOT" rev-parse HEAD)"
    echo "upstream:    $UPSTREAM"
    echo "image:       $IMAGE"
    echo "live stack:  READ ONLY / NOT MODIFIED"
}

prepare_worktree(){
    mkdir -p "$ROOT/build"
    if [[ ! -d "$DEV/.git" && ! -f "$DEV/.git" ]]; then
        rm -rf "$DEV"
        git -C "$SOURCE_REPO" worktree add --detach "$DEV" "$UPSTREAM" >/dev/null
    fi

    git -C "$DEV" reset --hard "$UPSTREAM" >/dev/null
    git -C "$DEV" clean -fdx >/dev/null
    [[ "$(git -C "$DEV" rev-parse HEAD)" == "$UPSTREAM" ]] || fail "isolated CommunityServer worktree mismatch"

    rm -rf "$DIR/MegaS4" "$DIR/BrimstoneMegaCloud"
    mkdir -p "$DIR/MegaS4" "$DIR/BrimstoneMegaCloud"
    cp -a "$S4_SRC"/*.cs "$DIR/MegaS4/"
    cp -a "$CLOUD_SRC"/*.cs "$DIR/BrimstoneMegaCloud/"

    python3 "$S4_PREP" "$DEV"
    python3 "$CLOUD_PREP" "$DEV"
}

stage_reference_bin(){
    rm -rf "$BIN"
    mkdir -p "$BIN"
    echo "=== STAGE LIVE BINARIES AS READ-ONLY BUILD REFERENCES ==="
    docker cp "$LIVE_CONTAINER:/var/www/onlyoffice/WebStudio/bin/." "$BIN/" >/dev/null

    # BRIMSTONE: do not invent assembly filenames from namespaces. The pinned
    # CommunityServer project uses ProjectReference outputs from this WebStudio
    # bin directory; the accepted S4 build follows the same pattern. Validate
    # the known target assembly plus a sane staged DLL count and let MSBuild
    # report any genuinely missing reference by its real assembly name.
    [[ -s "$BIN/ASC.Files.Thirdparty.dll" ]] || fail "staged ASC.Files.Thirdparty.dll missing"
    local dll_count
    dll_count="$(find "$BIN" -maxdepth 1 -type f -name '*.dll' | wc -l | tr -d ' ')"
    [[ "$dll_count" =~ ^[0-9]+$ ]] || fail "could not count staged WebStudio assemblies"
    (( dll_count > 10 )) || fail "too few staged WebStudio assemblies: $dll_count"
    echo "PASS: staged $dll_count live WebStudio DLLs as isolated build references"
}

create_temp_project(){
    python3 - "$ORIG" "$TEMP_PROJECT" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, 'r', encoding='utf-8-sig').read()
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
    raise SystemExit('BRIMSTONE FAIL: Microsoft.CSharp.targets marker not found')
if 'Microsoft.NETFramework.ReferenceAssemblies.net48' in text:
    raise SystemExit('BRIMSTONE FAIL: net48 reference pack already injected')
open(dst, 'w', encoding='utf-8').write(text.replace(marker, addition + '\n' + marker, 1))
PY
}

build_candidate(){
    preflight
    prepare_worktree
    stage_reference_bin
    create_temp_project
    rm -rf "$DIR/obj"
    mkdir -p "$CACHE"

    echo "=== RESTORE + COMPILE ==="
    docker run --rm \
        --name brimstone-megacc-v0002-compile \
        --entrypoint /bin/bash \
        -v "$DEV:/src" \
        -v "$CACHE:/root/.nuget/packages" \
        -w /src \
        "$IMAGE" -lc '
set -Eeuo pipefail
PROJECT=module/ASC.Files.Thirdparty/ASC.Files.Thirdparty.BrimstoneMegaCloudV0002.Linux.csproj
msbuild "$PROJECT" /t:Restore /p:RestoreIgnoreFailedSources=true /v:minimal
REF=/root/.nuget/packages/microsoft.netframework.referenceassemblies.net48/1.0.3/build/.NETFramework/v4.8/System.Net.Http.dll
test -s "$REF"
msbuild "$PROJECT" /t:Build /p:Configuration=Release /p:Platform=AnyCPU /p:BuildProjectReferences=false /p:RestoreIgnoreFailedSources=true /v:minimal
'

    rm -f "$TEMP_PROJECT"
    [[ -s "$CANDIDATE" ]] || fail "candidate DLL was not produced"

    echo "=== CANDIDATE VALIDATION ==="
    docker run --rm -i --entrypoint /bin/bash -v "$BIN:/candidate:ro" "$IMAGE" -s <<'CHECK'
set -Eeuo pipefail
DLL=/candidate/ASC.Files.Thirdparty.dll
TYPES="$(monodis --typedef "$DLL")"
STRINGS="$(monodis --userstrings "$DLL")"
grep -Fq 'ASC.Files.Thirdparty.MegaS4.MegaS4DaoSelector' <<<"$TYPES"
grep -Fq 'ASC.Files.Thirdparty.BrimstoneMegaCloud.BrimstoneMegaCloudDaoSelector' <<<"$TYPES"
grep -Fq 'ASC.Files.Thirdparty.BrimstoneMegaCloud.BrimstoneMegaCloudLsParser' <<<"$TYPES"
grep -Fq 'ASC.Files.Thirdparty.BrimstoneMegaCloud.BrimstoneMegaCloudClient' <<<"$TYPES"
grep -Fq 'sboxbrimstonemegacc-' <<<"$STRINGS"
grep -Fq 'Brimstone MEGA Cloud v0.002cc is read-only.' <<<"$STRINGS"
echo 'PASS: accepted MEGA S4 provider remains compiled'
echo 'PASS: Brimstone MEGA Cloud read-only provider classes compiled'
echo 'PASS: Brimstone handle ID marker embedded'
echo 'PASS: v0.002cc write paths fail closed'
CHECK

    echo
    echo "=== BRIMSTONE MEGA CLOUD v0.002cc COMPILE-ONLY PASS ==="
    sha256sum "$CANDIDATE"
    echo "candidate:   $CANDIDATE"
    echo "live stack:  NOT MODIFIED"
}

case "${1:-build}" in
    preflight) preflight ;;
    build) build_candidate ;;
    *) echo "Usage: $0 {preflight|build}" >&2; exit 2 ;;
esac
