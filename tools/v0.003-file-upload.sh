#!/usr/bin/env bash
set -Eeuo pipefail

# BRIMSTONE CUSTOM CODE — v0.003 file-upload build gate.
# Fix under test: preserve external sboxmega IDs across ChunkedUploadSession HTTP requests.
# This script does NOT deploy anything.

MODE="${1:-preflight}"
REPO="${REPO:-/opt/mega-cloud-connectors-for-onlyoffice}"
DEV="${DEV:-/opt/communityserver-megas4-dev}"
IMAGE="${IMAGE:-onlyoffice/communityserver:12.8.0.1971}"
C="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
DB="${MYSQL_CONTAINER:-onlyoffice-mysql-server}"
CACHE="${CACHE:-/opt/megas4-nuget-cache}"
UPSTREAM="fe1fa7babd093969e939ba6ff45a9fee1299dc93"
EXPECTED_LIVE="11864dfba74e7299b407439b54b4fc0fcfb3b7db32bb9526dd889b2476ae7c54"

SRC="$REPO/src/mega-s4/communityserver-12.8/MegaS4"
PREP="$REPO/tools/prepare-communityserver-source.py"
DIR="$DEV/module/ASC.Files.Thirdparty"
ORIG="$DIR/ASC.Files.Thirdparty.csproj"
BUILD="$DIR/ASC.Files.Thirdparty.BrimstoneV0003.Linux.csproj"
BIN="$DEV/web/studio/ASC.Web.Studio/bin"
CANDIDATE="$BIN/ASC.Files.Thirdparty.dll"
LIVE_DLL="/var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll"

trap 'rm -f "$BUILD"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }
live_hash(){ docker exec "$C" sha256sum "$LIVE_DLL" | awk '{print $1}'; }
mysql_scalar(){
  local sql="$1"
  docker exec -e SQL="$sql" "$DB" sh -lc 'mysql --batch --raw --skip-column-names -uroot -p"$MYSQL_ROOT_PASSWORD" onlyoffice -e "$SQL"' 2>/dev/null | tr -d '\r'
}
mega_rows(){ mysql_scalar "SELECT COUNT(*) FROM files_thirdparty_account WHERE LOWER(provider)='megas4';"; }
mega_maps(){ mysql_scalar "SELECT COUNT(*) FROM files_thirdparty_id_mapping WHERE id LIKE 'sboxmega-%' OR hash_id LIKE 'sboxmega-%';"; }

preflight(){
  echo "============================================================"
  echo " BRIMSTONE MEGA S4 v0.003 — FILE UPLOAD PRE-FLIGHT"
  echo "============================================================"

  [[ -d "$REPO/.git" ]] || fail "repo missing: $REPO"
  [[ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" == "v0.003-file-upload" ]] || fail "checkout v0.003-file-upload first"
  [[ -z "$(git -C "$REPO" status --porcelain)" ]] || fail "connector worktree is not clean"
  [[ -s "$PREP" ]] || fail "source preparer missing"
  [[ -d "$DEV/.git" ]] || fail "CommunityServer source tree missing: $DEV"
  [[ "$(git -C "$DEV" rev-parse HEAD)" == "$UPSTREAM" ]] || fail "CommunityServer HEAD mismatch"

  python3 - "$SRC/MegaS4FileDao.cs" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
required = [
    'private File RestoreIds(File file)',
    'file.ID = MakeId(DecodeId(file.ID));',
    'file.FolderID = MakeId(DecodeId(file.FolderID));',
    'new ChunkedUploadSession(RestoreIds(file), contentLength)',
    'session.File = RestoreIds(session.File);',
    'BRIMSTONE CUSTOM CODE: ProviderFileDao converts third-party IDs',
]
for needle in required:
    assert needle in text, 'missing source contract: ' + needle
assert text.count('session.File = RestoreIds(session.File);') >= 2, 'RestoreIds must run at session creation and between chunks'
print('PASS: v0.003 chunk-ID lifecycle source contract present')
PY

  docker inspect "$C" >/dev/null 2>&1 || fail "CommunityServer container missing"
  docker inspect "$DB" >/dev/null 2>&1 || fail "MySQL container missing"
  [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer not running"
  [[ "$(docker inspect -f '{{.State.Running}}' "$DB")" == "true" ]] || fail "MySQL not running"
  [[ "$(docker inspect -f '{{.Config.Image}}' "$C")" == "$IMAGE" ]] || fail "CommunityServer image mismatch"
  [[ "$(live_hash)" == "$EXPECTED_LIVE" ]] || fail "unexpected live DLL: $(live_hash)"

  echo "PASS: exact v0.002 live DLL is the deployment baseline"
  echo "INFO: existing MEGA rows are preserved: $(mega_rows)"
  echo "INFO: existing MEGA mappings are preserved: $(mega_maps)"
}

build_candidate(){
  preflight
  local rows_before maps_before
  rows_before="$(mega_rows)"
  maps_before="$(mega_maps)"

  echo
  echo "=== PREPARE EXACT COMMUNITYSERVER SOURCE ==="
  rm -rf "$DIR/MegaS4"
  mkdir -p "$DIR/MegaS4"
  cp -a "$SRC"/*.cs "$DIR/MegaS4/"
  python3 "$PREP" "$DEV"

  echo
  echo "=== STAGE LIVE WEBSTUDIO BINARIES AS REFERENCES ==="
  rm -rf "$BIN"
  mkdir -p "$BIN"
  docker cp "$C:/var/www/onlyoffice/WebStudio/bin/." "$BIN/" >/dev/null
  [[ "$(sha256sum "$BIN/ASC.Files.Thirdparty.dll" | awk '{print $1}')" == "$EXPECTED_LIVE" ]] || fail "staged live DLL mismatch"

  echo
  echo "=== CREATE TEMPORARY NET48 BUILD PROJECT ==="
  python3 - "$ORIG" "$BUILD" <<'PY'
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
    raise SystemExit('FAIL: Microsoft.CSharp.targets marker not found')
if 'Microsoft.NETFramework.ReferenceAssemblies.net48' in text:
    raise SystemExit('FAIL: net48 reference pack already injected')
open(dst, 'w', encoding='utf-8').write(text.replace(marker, addition + '\n' + marker, 1))
PY

  rm -rf "$DIR/obj"
  mkdir -p "$CACHE"

  echo
  echo "=== RESTORE + BUILD ==="
  docker run --rm \
    --name brimstone-megas4-v0003-build \
    --entrypoint /bin/bash \
    -v "$DEV:/src" \
    -v "$CACHE:/root/.nuget/packages" \
    -w /src \
    "$IMAGE" \
    -lc '
      set -euo pipefail
      PROJECT=module/ASC.Files.Thirdparty/ASC.Files.Thirdparty.BrimstoneV0003.Linux.csproj
      msbuild "$PROJECT" /t:Restore /p:RestoreIgnoreFailedSources=true /v:minimal
      REF=/root/.nuget/packages/microsoft.netframework.referenceassemblies.net48/1.0.3/build/.NETFramework/v4.8/System.Net.Http.dll
      test -s "$REF"
      ASM="$(monodis --assembly "$REF")"
      grep -Fq "Version:       4.2.0.0" <<<"$ASM"
      msbuild "$PROJECT" /t:Build /p:Configuration=Release /p:Platform=AnyCPU /p:BuildProjectReferences=false /p:RestoreIgnoreFailedSources=true /v:minimal
    '

  rm -f "$BUILD"
  [[ -s "$CANDIDATE" ]] || fail "candidate DLL was not produced"

  local new
  new="$(sha256sum "$CANDIDATE" | awk '{print $1}')"
  [[ "$new" != "$EXPECTED_LIVE" ]] || fail "candidate DLL is unchanged"

  echo
  echo "=== CANDIDATE CLR VALIDATION ==="
  docker run --rm -i --entrypoint /bin/bash -v "$BIN:/candidate:ro" "$IMAGE" -s <<'CHECK'
set -euo pipefail
DLL=/candidate/ASC.Files.Thirdparty.dll
TYPES="$(monodis --typedef "$DLL")"
METHODS="$(monodis --method "$DLL")"
STRINGS="$(monodis --userstrings "$DLL")"
REFS="$(monodis --assemblyref "$DLL")"
grep -Fq 'ASC.Files.Thirdparty.MegaS4.MegaS4FileDao' <<<"$TYPES"
grep -Fq 'RestoreIds' <<<"$METHODS"
grep -Fq 'sboxmega-' <<<"$STRINGS"
grep -Fq 'Name=AWSSDK.S3' <<<"$REFS"
grep -Fq 'Name=AWSSDK.Core' <<<"$REFS"
echo 'PASS: MegaS4FileDao present'
echo 'PASS: RestoreIds compiled into candidate'
echo 'PASS: sboxmega ID namespace retained'
echo 'PASS: AWS SDK references retained'
CHECK

  [[ "$(mega_rows)" == "$rows_before" ]] || fail "MEGA account rows changed during build"
  [[ "$(mega_maps)" == "$maps_before" ]] || fail "MEGA mappings changed during build"

  echo
  echo "============================================================"
  echo " PASS — v0.003 FILE-UPLOAD CANDIDATE BUILT"
  echo "============================================================"
  echo "Candidate : $CANDIDATE"
  echo "SHA256    : $new"
  echo "Live DLL  : $EXPECTED_LIVE"
  echo "MEGA rows : $(mega_rows) (unchanged)"
  echo "MEGA maps : $(mega_maps) (unchanged)"
  echo "LIVE ONLYOFFICE WAS NOT MODIFIED."
  echo "============================================================"
}

status(){
  echo "Live DLL : $(live_hash 2>/dev/null || echo unavailable)"
  echo "Mega rows: $(mega_rows 2>/dev/null || echo unavailable)"
  echo "Mega maps: $(mega_maps 2>/dev/null || echo unavailable)"
  if [[ -s "$CANDIDATE" ]]; then
    echo "Candidate: $(sha256sum "$CANDIDATE" | awk '{print $1}')"
  else
    echo "Candidate: missing"
  fi
}

case "$MODE" in
  preflight) preflight ;;
  build) build_candidate ;;
  status) status ;;
  *) echo "Usage: $0 {preflight|build|status}" >&2; exit 2 ;;
esac
