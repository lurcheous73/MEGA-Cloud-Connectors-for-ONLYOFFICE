#!/usr/bin/env bash
# BRIMSTONE CUSTOM CODE — canonical combined S4 + MEGA Cloud builder.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="onlyoffice/communityserver:12.8.0.1971"
LIVE_CONTAINER="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
SOURCE_REPO="${COMMUNITYSERVER_SOURCE_REPO:-/opt/communityserver-megas4-dev}"
SOURCE_URL="${COMMUNITYSERVER_SOURCE_URL:-https://github.com/ONLYOFFICE/CommunityServer.git}"
UPSTREAM="fe1fa7babd093969e939ba6ff45a9fee1299dc93"
DEV="$ROOT/build/communityserver-release-src"
CACHE="$ROOT/build/communityserver-release-nuget-cache"
S4_SRC="$ROOT/src/mega-s4/communityserver-12.8/MegaS4"
CLOUD_SRC="$ROOT/src/mega-cloud/communityserver-12.8/BrimstoneMegaCloud"
S4_PREP="$ROOT/tools/prepare-communityserver-source.py"
CLOUD_PREP="$ROOT/tools/prepare-communityserver-mega-cloud-v0.002cc.py"
DIR="$DEV/module/ASC.Files.Thirdparty"
ORIG="$DIR/ASC.Files.Thirdparty.csproj"
TEMP_PROJECT="$DIR/ASC.Files.Thirdparty.BrimstoneCombined.Linux.csproj"
BIN="$DEV/web/studio/ASC.Web.Studio/bin"
CANDIDATE="$BIN/ASC.Files.Thirdparty.dll"

fail(){ echo "BRIMSTONE BUILD FAIL: $*" >&2; exit 1; }

ensure_source_repo(){
    if [[ ! -d "$SOURCE_REPO/.git" ]]; then
        echo "=== BOOTSTRAP PINNED COMMUNITYSERVER SOURCE ==="
        command -v git >/dev/null 2>&1 || fail "git is required"
        mkdir -p "$(dirname "$SOURCE_REPO")"
        git clone --filter=blob:none --no-checkout "$SOURCE_URL" "$SOURCE_REPO"
    fi
    if ! git -C "$SOURCE_REPO" cat-file -e "$UPSTREAM^{commit}" 2>/dev/null; then
        echo "Fetching pinned CommunityServer commit $UPSTREAM ..."
        git -C "$SOURCE_REPO" fetch --no-tags origin "$UPSTREAM"
    fi
    git -C "$SOURCE_REPO" cat-file -e "$UPSTREAM^{commit}" 2>/dev/null || fail "pinned CommunityServer commit unavailable"
}

preflight(){
    echo "============================================================"
    echo " BRIMSTONE — COMBINED CONNECTOR BUILD PREFLIGHT"
    echo "============================================================"
    [[ -d "$ROOT/.git" || -f "$ROOT/.git" ]] || fail "connector repository missing"
    [[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]] || fail "connector repository is dirty"
    command -v docker >/dev/null 2>&1 || fail "docker is required"
    command -v python3 >/dev/null 2>&1 || fail "python3 is required"
    docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "required builder image is not local: $IMAGE"
    docker inspect "$LIVE_CONTAINER" >/dev/null 2>&1 || fail "CommunityServer container missing: $LIVE_CONTAINER"
    [[ "$(docker inspect -f '{{.Config.Image}}' "$LIVE_CONTAINER")" == "$IMAGE" ]] || fail "unsupported live CommunityServer image"
    [[ -d "$S4_SRC" ]] || fail "accepted MEGA S4 source missing"
    [[ -d "$CLOUD_SRC" ]] || fail "MEGA Cloud source missing"
    [[ -s "$S4_PREP" ]] || fail "S4 preparer missing"
    [[ -s "$CLOUD_PREP" ]] || fail "Cloud preparer missing"

    grep -Fq 'private const string Prefix = "sboxmega-";' "$S4_SRC/MegaS4Id.cs" || fail "accepted sboxmega ID prefix missing from S4 source"
    grep -Fq '^sboxmega-\d+' "$S4_SRC/MegaS4DaoSelector.cs" || fail "accepted sboxmega selector missing from S4 source"
    ! grep -RqsF 'sbox-megas4-' "$S4_SRC" || fail "obsolete sbox-megas4 namespace present in S4 source"
    ! grep -Fq 'private File RestoreIds' "$S4_SRC/MegaS4FileDao.cs" || fail "unaccepted RestoreIds chunk-session regression is present"

    ensure_source_repo
    echo "repo commit : $(git -C "$ROOT" rev-parse HEAD)"
    echo "upstream    : $UPSTREAM"
    echo "image       : $IMAGE"
    echo "live stack  : READ-ONLY BUILD REFERENCES ONLY"
}

prepare_worktree(){
    echo "=== PREPARE ISOLATED COMMUNITYSERVER WORKTREE ==="
    mkdir -p "$ROOT/build"
    if [[ ! -d "$DEV/.git" && ! -f "$DEV/.git" ]]; then
        rm -rf "$DEV"
        git -C "$SOURCE_REPO" worktree prune >/dev/null 2>&1 || true
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

    echo "=== PROVIDER REGISTRATION SOURCE CONTRACT ==="
    grep -Fq '            MegaS4,' "$DIR/ProviderAccountDao.cs" || fail "MegaS4 provider enum missing"
    grep -Fq 'return new MegaS4ProviderInfo(' "$DIR/ProviderAccountDao.cs" || fail "MegaS4 provider materialisation missing"
    grep -Fq 'Selectors.Add(new MegaS4DaoSelector());' "$DIR/ProviderDao/ProviderDaoBase.cs" || fail "MegaS4 selector registration missing"
    grep -Fq '            BrimstoneMegaCloud,' "$DIR/ProviderAccountDao.cs" || fail "BrimstoneMegaCloud provider enum missing"
    grep -Fq 'return new BrimstoneMegaCloudProviderInfo(' "$DIR/ProviderAccountDao.cs" || fail "BrimstoneMegaCloud materialisation missing"
    grep -Fq 'case ProviderTypes.BrimstoneMegaCloud:' "$DIR/ProviderAccountDao.cs" || fail "BrimstoneMegaCloud state-slot handling missing"
    grep -Fq 'Selectors.Add(new BrimstoneMegaCloudDaoSelector());' "$DIR/ProviderDao/ProviderDaoBase.cs" || fail "BrimstoneMegaCloud selector registration missing"
    echo "PASS: both providers registered in the same source tree"
}

stage_reference_bin(){
    echo "=== STAGE LIVE WEBSTUDIO DLLS AS ISOLATED BUILD REFERENCES ==="
    rm -rf "$BIN"
    mkdir -p "$BIN"
    docker cp "$LIVE_CONTAINER:/var/www/onlyoffice/WebStudio/bin/." "$BIN/" >/dev/null
    [[ -s "$BIN/ASC.Files.Thirdparty.dll" ]] || fail "staged ASC.Files.Thirdparty.dll missing"
    local count
    count="$(find "$BIN" -maxdepth 1 -type f -name '*.dll' | wc -l | tr -d ' ')"
    [[ "$count" =~ ^[0-9]+$ ]] || fail "could not count staged DLLs"
    (( count > 10 )) || fail "too few staged WebStudio DLLs: $count"
    echo "PASS: staged $count live WebStudio DLLs"
}

create_temp_project(){
    python3 - "$ORIG" "$TEMP_PROJECT" <<'PY'
import sys
src,dst=sys.argv[1:]
text=open(src,'r',encoding='utf-8-sig').read()
marker='  <Import Project="$(MSBuildToolsPath)\\Microsoft.CSharp.targets" />'
addition=r'''  <ItemGroup>
    <PackageReference Include="Microsoft.NETFramework.ReferenceAssemblies.net48">
      <Version>1.0.3</Version>
      <PrivateAssets>all</PrivateAssets>
      <IncludeAssets>runtime; build; native; contentfiles; analyzers</IncludeAssets>
    </PackageReference>
  </ItemGroup>
'''
if marker not in text: raise SystemExit('BRIMSTONE BUILD FAIL: Microsoft.CSharp.targets marker not found')
if 'Microsoft.NETFramework.ReferenceAssemblies.net48' in text: raise SystemExit('BRIMSTONE BUILD FAIL: net48 reference pack already injected')
open(dst,'w',encoding='utf-8').write(text.replace(marker,addition+'\n'+marker,1))
PY
}

validate_candidate(){
    echo "=== CANDIDATE VALIDATION ==="
    docker run --rm -i \
      --entrypoint /bin/bash \
      -v "$BIN:/candidate:ro" \
      "$IMAGE" -s <<'CHECK'
set -Eeuo pipefail
DLL=/candidate/ASC.Files.Thirdparty.dll
TYPES="$(monodis --typedef "$DLL")"
STRINGS="$(monodis --userstrings "$DLL")"
grep -Fq 'ASC.Files.Thirdparty.MegaS4.MegaS4DaoSelector' <<<"$TYPES"
grep -Fq 'ASC.Files.Thirdparty.MegaS4.BrimstoneMegaS4Handler' <<<"$TYPES"
grep -Fq 'ASC.Files.Thirdparty.BrimstoneMegaCloud.BrimstoneMegaCloudDaoSelector' <<<"$TYPES"
grep -Fq 'ASC.Files.Thirdparty.BrimstoneMegaCloud.BrimstoneMegaCloudClient' <<<"$TYPES"
grep -Fq 'ASC.Files.Thirdparty.BrimstoneMegaCloud.BrimstoneMegaCloudFileDao' <<<"$TYPES"
grep -Fq 'ASC.Files.Thirdparty.BrimstoneMegaCloud.BrimstoneMegaCloudFolderDao' <<<"$TYPES"
grep -Fq 'sboxmega-' <<<"$STRINGS"
if grep -Fq 'sbox-megas4-' <<<"$STRINGS"; then echo 'FAIL: obsolete sbox-megas4 namespace compiled' >&2; exit 1; fi
grep -Fq 'sboxbrimstonemegacc-' <<<"$STRINGS"
grep -Fq 'BRIMSTONE MEGA S4 handler error:' <<<"$STRINGS"
grep -Fq 'Large chunked MEGA Cloud uploads are not enabled yet.' <<<"$STRINGS"
grep -Fq 'Brimstone MEGA Cloud operation is not enabled in v0.004cc create/edit.' <<<"$STRINGS"
echo 'PASS: accepted MEGA S4 provider compiled'
echo 'PASS: browser-compatible sboxmega namespace compiled'
echo 'PASS: obsolete sbox-megas4 namespace absent'
echo 'PASS: Brimstone MEGA Cloud provider compiled in shared DLL'
CHECK
}

build(){
    preflight
    prepare_worktree
    stage_reference_bin
    create_temp_project
    rm -rf "$DIR/obj"
    mkdir -p "$CACHE"

    echo "=== RESTORE + COMPILE ==="
    docker run --rm \
      --name brimstone-connectors-release-compile \
      --entrypoint /bin/bash \
      -v "$DEV:/src" \
      -v "$CACHE:/root/.nuget/packages" \
      -w /src \
      "$IMAGE" -lc '
set -Eeuo pipefail
PROJECT=module/ASC.Files.Thirdparty/ASC.Files.Thirdparty.BrimstoneCombined.Linux.csproj
msbuild "$PROJECT" /t:Restore /p:RestoreIgnoreFailedSources=true /v:minimal
REF=/root/.nuget/packages/microsoft.netframework.referenceassemblies.net48/1.0.3/build/.NETFramework/v4.8/System.Net.Http.dll
test -s "$REF"
msbuild "$PROJECT" /t:Build /p:Configuration=Release /p:Platform=AnyCPU /p:BuildProjectReferences=false /p:RestoreIgnoreFailedSources=true /v:minimal
'

    rm -f "$TEMP_PROJECT"
    [[ -s "$CANDIDATE" ]] || fail "candidate DLL was not produced"
    validate_candidate
    echo
    echo "============================================================"
    echo " BRIMSTONE — COMBINED BUILD PASS"
    echo "============================================================"
    sha256sum "$CANDIDATE"
    echo "candidate: $CANDIDATE"
    echo "live stack: NOT MODIFIED"
}

case "${1:-build}" in
  preflight) preflight ;;
  build) build ;;
  path) printf '%s\n' "$CANDIDATE" ;;
  *) echo "Usage: $0 {preflight|build|path}" >&2; exit 2 ;;
esac
