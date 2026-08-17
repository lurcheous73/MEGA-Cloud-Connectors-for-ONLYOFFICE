#!/usr/bin/env bash
# BRIMSTONE CUSTOM CODE — v0.002cc compile-only gate.
# Builds the accepted MEGA S4 integration plus the new normal-MEGA Cloud
# read-only DAO slice against the exact CommunityServer 12.8 source/image.
# It never copies a candidate into the live container and never restarts it.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRANCH="v0.005cc-mega-cloud-full-write"
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
    echo "=== BRIMSTONE MEGA CLOUD v0.005cc COMPILE-ONLY PREFLIGHT ==="
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

    echo "=== BRIMSTONE PROVIDER REGISTRATION SOURCE CONTRACT ==="
    grep -Fq '            BrimstoneMegaCloud,' "$DIR/ProviderAccountDao.cs" ||
        fail "BrimstoneMegaCloud provider enum was not prepared"
    grep -Fq 'return new BrimstoneMegaCloudProviderInfo(' "$DIR/ProviderAccountDao.cs" ||
        fail "BrimstoneMegaCloud provider materialisation was not prepared"
    grep -Fq 'case ProviderTypes.BrimstoneMegaCloud:' "$DIR/ProviderAccountDao.cs" ||
        fail "BrimstoneMegaCloud state-slot handling was not prepared"
    grep -Fq 'Selectors.Add(new BrimstoneMegaCloudDaoSelector());' "$DIR/ProviderDao/ProviderDaoBase.cs" ||
        fail "BrimstoneMegaCloud selector registration was not prepared"
    echo "PASS: provider enum, materialisation, state-slot handling and selector registration are present"
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
    docker run --rm -i \
        --entrypoint /bin/bash \
        -v "$BIN:/candidate:ro" \
        "$IMAGE" -s <<'CHECK'
set -Eeuo pipefail

DLL=/candidate/ASC.Files.Thirdparty.dll

TYPES="$(monodis --typedef "$DLL")"
STRINGS="$(monodis --userstrings "$DLL")"

grep -Fq \
  'ASC.Files.Thirdparty.MegaS4.MegaS4DaoSelector' \
  <<<"$TYPES"

grep -Fq \
  'ASC.Files.Thirdparty.BrimstoneMegaCloud.BrimstoneMegaCloudDaoSelector' \
  <<<"$TYPES"

grep -Fq \
  'ASC.Files.Thirdparty.BrimstoneMegaCloud.BrimstoneMegaCloudClient' \
  <<<"$TYPES"

grep -Fq \
  'ASC.Files.Thirdparty.BrimstoneMegaCloud.BrimstoneMegaCloudFileDao' \
  <<<"$TYPES"

grep -Fq \
  'ASC.Files.Thirdparty.BrimstoneMegaCloud.BrimstoneMegaCloudFolderDao' \
  <<<"$TYPES"

grep -Fq \
  'sboxbrimstonemegacc-' \
  <<<"$STRINGS"

# New v0.004cc write-path fingerprints.
grep -Fq \
  'Unable to secure staged Brimstone MEGA Cloud upload.' \
  <<<"$STRINGS"

grep -Fq \
  'Large chunked MEGA Cloud uploads are not enabled yet.' \
  <<<"$STRINGS"

grep -Fq \
  'MEGA Cloud rename is not enabled in v0.004cc create/edit.' \
  <<<"$STRINGS"

grep -Fq \
  'Brimstone MEGA Cloud operation is not enabled in v0.004cc create/edit.' \
  <<<"$STRINGS"

echo 'PASS: accepted MEGA S4 provider remains compiled'
echo 'PASS: Brimstone MEGA Cloud provider remains compiled'
echo 'PASS: live-path ID namespace remains compiled'
echo 'PASS: v0.004cc create/edit code is present'
echo 'PASS: restricted-operation fail-closed code remains present'
CHECK

    echo
    echo "=== v0.005cc CREATE/EDIT BASE CONTRACT ==="

    # Writable operations that MUST now exist.
    grep -Fq \
      'public File SaveFile(File file, Stream fileStream)' \
      "$CLOUD_SRC/BrimstoneMegaCloudFileDao.cs"

    grep -Fq \
      'public File ReplaceFileVersion(File file, Stream fileStream)' \
      "$CLOUD_SRC/BrimstoneMegaCloudFileDao.cs"

    grep -Fq \
      'public object SaveFolder(Folder folder)' \
      "$CLOUD_SRC/BrimstoneMegaCloudFolderDao.cs"

    grep -Fq \
      'public BrimstoneMegaCloudEntry Put(' \
      "$CLOUD_SRC/BrimstoneMegaCloudClient.cs"

    grep -Fq \
      'public BrimstoneMegaCloudEntry CreateFolder(' \
      "$CLOUD_SRC/BrimstoneMegaCloudClient.cs"

    # Old read-only implementations MUST NOT remain on create/edit.
    if grep -Fq \
      'public File SaveFile(File file, Stream fileStream) { throw ReadOnly(); }' \
      "$CLOUD_SRC/BrimstoneMegaCloudFileDao.cs"
    then
        fail "SaveFile is still read-only"
    fi

    if grep -Fq \
      'public object SaveFolder(Folder folder) { throw ReadOnly(); }' \
      "$CLOUD_SRC/BrimstoneMegaCloudFolderDao.cs"
    then
        fail "SaveFolder is still read-only"
    fi

    echo "PASS: file create/save enabled"
    echo "PASS: file version replacement enabled"
    echo "PASS: folder create enabled"

    echo
    echo "=== v0.005cc FULL-WRITE CAPABILITY CONTRACT ==="

grep -Fq \
    'public BrimstoneMegaCloudEntry Move(' \
    "$CLOUD_SRC/BrimstoneMegaCloudClient.cs" ||
    fail "v0.005 client Move is missing"

grep -Fq \
    'public BrimstoneMegaCloudEntry Copy(' \
    "$CLOUD_SRC/BrimstoneMegaCloudClient.cs" ||
    fail "v0.005 client Copy is missing"

grep -Fq \
    'public void MoveToRubbish(' \
    "$CLOUD_SRC/BrimstoneMegaCloudClient.cs" ||
    fail "v0.005 safe-delete implementation is missing"

grep -Fq \
    '+ " //bin"' \
    "$CLOUD_SRC/BrimstoneMegaCloudClient.cs" ||
    fail "v0.005 safe delete does not target MEGA Rubbish Bin"

if grep -Fq \
    '"rm ' \
    "$CLOUD_SRC/BrimstoneMegaCloudClient.cs"
then
    fail "permanent MEGA rm command must never be exposed"
fi

grep -Fq \
    'public object MoveFile(' \
    "$CLOUD_SRC/BrimstoneMegaCloudFileDao.cs" ||
    fail "file move is missing"

grep -Fq \
    'public File CopyFile(' \
    "$CLOUD_SRC/BrimstoneMegaCloudFileDao.cs" ||
    fail "file copy is missing"

grep -Fq \
    'public object FileRename(' \
    "$CLOUD_SRC/BrimstoneMegaCloudFileDao.cs" ||
    fail "file rename is missing"

grep -Fq \
    'ProviderInfo.Client.MoveToRubbish(' \
    "$CLOUD_SRC/BrimstoneMegaCloudFileDao.cs" ||
    fail "file safe-delete is missing"

grep -Fq \
    'public object MoveFolder(' \
    "$CLOUD_SRC/BrimstoneMegaCloudFolderDao.cs" ||
    fail "folder move is missing"

grep -Fq \
    'public Folder CopyFolder(' \
    "$CLOUD_SRC/BrimstoneMegaCloudFolderDao.cs" ||
    fail "folder copy is missing"

grep -Fq \
    'public object RenameFolder(' \
    "$CLOUD_SRC/BrimstoneMegaCloudFolderDao.cs" ||
    fail "folder rename is missing"

grep -Fq \
    'ProviderInfo.Client.MoveToRubbish(' \
    "$CLOUD_SRC/BrimstoneMegaCloudFolderDao.cs" ||
    fail "folder safe-delete is missing"

grep -Fq \
    'DenyReservedPath(sourcePath);' \
    "$CLOUD_SRC/BrimstoneMegaCloudClient.cs" ||
    fail "source S4 guard is missing"

grep -Fq \
    'DenyReservedPath(destinationPath);' \
    "$CLOUD_SRC/BrimstoneMegaCloudClient.cs" ||
    fail "destination S4 guard is missing"

echo "PASS: file rename enabled"
echo "PASS: file move enabled"
echo "PASS: file copy enabled"
echo "PASS: file safe delete -> MEGA //bin"
echo "PASS: folder rename enabled"
echo "PASS: folder move enabled"
echo "PASS: folder copy enabled"
echo "PASS: folder safe delete -> MEGA //bin"
echo "PASS: permanent MEGA rm absent"
echo "PASS: source/destination S4 guards present"

echo
echo "=== BRIMSTONE MEGA CLOUD v0.005cc COMPILE-ONLY PASS ==="
    sha256sum "$CANDIDATE"
    echo "candidate:   $CANDIDATE"
    echo "live stack:  NOT MODIFIED"
}

case "${1:-build}" in
    preflight) preflight ;;
    build) build_candidate ;;
    *) echo "Usage: $0 {preflight|build}" >&2; exit 2 ;;
esac
