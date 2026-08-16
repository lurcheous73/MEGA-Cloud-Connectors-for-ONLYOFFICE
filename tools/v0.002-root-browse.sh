#!/usr/bin/env bash
set -Eeuo pipefail

# BRIMSTONE CUSTOM CODE — v0.002 root-browse build/deploy gate.
# Fix under test: browser-compatible provider IDs use sboxmega-<providerId>.

MODE="${1:-install}"
REPO="${REPO:-/opt/mega-cloud-connectors-for-onlyoffice}"
DEV="${DEV:-/opt/communityserver-megas4-dev}"
IMAGE="${IMAGE:-onlyoffice/communityserver:12.8.0.1971}"
C="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
DB="${MYSQL_CONTAINER:-onlyoffice-mysql-server}"
CACHE="${CACHE:-/opt/megas4-nuget-cache}"
UPSTREAM="fe1fa7babd093969e939ba6ff45a9fee1299dc93"
EXPECTED_LIVE="2e5b17bd0e3c7c216428e58e0163c1aacac707cbada4f49edd849daf80cdb787"

SRC="$REPO/src/mega-s4/communityserver-12.8/MegaS4"
PREP="$REPO/tools/prepare-communityserver-source.py"
DIR="$DEV/module/ASC.Files.Thirdparty"
ORIG="$DIR/ASC.Files.Thirdparty.csproj"
BUILD="$DIR/ASC.Files.Thirdparty.BrimstoneV0002.Linux.csproj"
BIN="$DEV/web/studio/ASC.Web.Studio/bin"
CANDIDATE="$BIN/ASC.Files.Thirdparty.dll"
LIVE_DLL="/var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/mega-cloud-connectors-for-onlyoffice}"
STATE_DIR="${STATE_DIR:-/var/lib/mega-cloud-connectors-for-onlyoffice}"
STATE="$STATE_DIR/v0.002-root-browse.state"

# A stale temporary build project is never useful. Clean it on every exit.
trap 'rm -f "$BUILD"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }
live_hash(){ docker exec "$C" sha256sum "$LIVE_DLL" | awk '{print $1}'; }
mysql_scalar(){
  local sql="$1"
  docker exec -e SQL="$sql" "$DB" sh -lc 'mysql --batch --raw --skip-column-names -uroot -p"$MYSQL_ROOT_PASSWORD" onlyoffice -e "$SQL"' 2>/dev/null | tr -d '\r'
}
mega_rows(){ mysql_scalar "SELECT COUNT(*) FROM files_thirdparty_account WHERE LOWER(provider)='megas4';"; }
mega_maps(){ mysql_scalar "SELECT COUNT(*) FROM files_thirdparty_id_mapping WHERE id LIKE 'sboxmega-%' OR id LIKE 'sbox-megas4-%' OR hash_id LIKE 'sboxmega-%' OR hash_id LIKE 'sbox-megas4-%';"; }

preflight(){
  echo "============================================================"
  echo " BRIMSTONE MEGA S4 v0.002 — ROOT BROWSE PRE-FLIGHT"
  echo "============================================================"

  [[ -d "$REPO/.git" ]] || fail "repo missing: $REPO"
  [[ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" == "v0.002-root-browse" ]] || fail "checkout v0.002-root-browse first"
  [[ -z "$(git -C "$REPO" status --porcelain)" ]] || fail "connector worktree is not clean"
  [[ -s "$PREP" ]] || fail "source preparer missing"
  [[ -d "$DEV/.git" ]] || fail "CommunityServer source tree missing: $DEV"
  [[ "$(git -C "$DEV" rev-parse HEAD)" == "$UPSTREAM" ]] || fail "CommunityServer HEAD mismatch"

  python3 - "$SRC/MegaS4Id.cs" "$SRC/MegaS4DaoSelector.cs" <<'PY'
import pathlib, re, sys
id_source = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
selector_source = pathlib.Path(sys.argv[2]).read_text(encoding='utf-8')
assert 'private const string Prefix = "sboxmega-";' in id_source, 'new ID prefix missing'
assert r'@"^sboxmega-\d+' in selector_source, 'new selector missing'
assert 'private const string Prefix = "sbox-megas4-";' not in id_source, 'old provider prefix remains active'

browser = re.compile(r'^(\d+|[a-z]+-\d+(-.+)*)')
sharpbox = re.compile(r'^sbox-\d+(-.*)?$')
mega = re.compile(r'^sboxmega-\d+(?:-[A-Za-z0-9_-]+)?$', re.I)
for value in ('sboxmega-8', 'sboxmega-8-Zm9vL2Jhci5kb2N4'):
    assert browser.match(value), value
    assert mega.match(value), value
    assert not sharpbox.match(value), value
assert not browser.match('sbox-megas4-8')
print('PASS: v0.002 source ID contract is present')
print('PASS: new IDs satisfy ONLYOFFICE browser grammar and cannot match SharpBox')
PY

  grep -Fq 'StartsWith("sbox")' "$DEV/web/studio/ASC.Web.Studio/Products/Files/Core/Dao/TeamlabDao/AbstractDao.cs" || fail "ONLYOFFICE sbox MappingID path missing"

  docker inspect "$C" >/dev/null 2>&1 || fail "CommunityServer container missing"
  docker inspect "$DB" >/dev/null 2>&1 || fail "MySQL container missing"
  [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer not running"
  [[ "$(docker inspect -f '{{.State.Running}}' "$DB")" == "true" ]] || fail "MySQL not running"
  [[ "$(docker inspect -f '{{.Config.Image}}' "$C")" == "$IMAGE" ]] || fail "CommunityServer image mismatch"
  [[ "$(live_hash)" == "$EXPECTED_LIVE" ]] || fail "unexpected live DLL: $(live_hash)"
  [[ "$(mega_rows)" == "0" ]] || fail "MEGA provider rows exist; delete the test connection before changing ID format"
  [[ "$(mega_maps)" == "0" ]] || fail "MEGA mapping rows exist; inspect them before changing ID format"

  echo "PASS: live baseline, clean DB and v0.002 source are suitable"
}

build_candidate(){
  preflight
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
    --name brimstone-megas4-v0002-build \
    --entrypoint /bin/bash \
    -v "$DEV:/src" \
    -v "$CACHE:/root/.nuget/packages" \
    -w /src \
    "$IMAGE" \
    -lc '
      set -euo pipefail
      PROJECT=module/ASC.Files.Thirdparty/ASC.Files.Thirdparty.BrimstoneV0002.Linux.csproj
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
STRINGS="$(monodis --userstrings "$DLL")"
REFS="$(monodis --assemblyref "$DLL")"
grep -Fq 'ASC.Files.Thirdparty.MegaS4.MegaS4DaoSelector' <<<"$TYPES"
grep -Fq 'ASC.Files.Thirdparty.MegaS4.MegaS4ProviderInfo' <<<"$TYPES"
grep -Fq 'sboxmega-' <<<"$STRINGS"
if grep -Fq 'sbox-megas4-' <<<"$STRINGS"; then
  echo 'FAIL: old sbox-megas4 prefix remains in CLR literals' >&2
  exit 1
fi
grep -Fq 'Name=AWSSDK.S3' <<<"$REFS"
grep -Fq 'Name=AWSSDK.Core' <<<"$REFS"
echo 'PASS: MEGA provider types present'
echo 'PASS: browser-compatible sboxmega ID prefix embedded'
echo 'PASS: old sbox-megas4 prefix absent from CLR literals'
echo 'PASS: AWS SDK references present'
CHECK

  echo "PASS: candidate built: $new"
}

restore(){
  local backup="$1"
  [[ -s "$backup/ASC.Files.Thirdparty.dll" ]] || fail "rollback DLL missing"
  docker stop "$C" >/dev/null || true
  docker cp "$backup/ASC.Files.Thirdparty.dll" "$C:$LIVE_DLL" >/dev/null
  docker start "$C" >/dev/null
  sleep 10
  [[ "$(live_hash)" == "$EXPECTED_LIVE" ]] || fail "rollback hash mismatch: $(live_hash)"
}

install(){
  build_candidate
  local new stamp backup mutated=0
  new="$(sha256sum "$CANDIDATE" | awk '{print $1}')"
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="$BACKUP_ROOT/brimstone-mega-s4-v0.002-root-browse-$stamp"
  mkdir -p "$backup" "$STATE_DIR"
  chmod 700 "$backup" "$STATE_DIR"
  docker cp "$C:$LIVE_DLL" "$backup/ASC.Files.Thirdparty.dll" >/dev/null
  [[ "$(sha256sum "$backup/ASC.Files.Thirdparty.dll" | awk '{print $1}')" == "$EXPECTED_LIVE" ]] || fail "backup hash mismatch"

  rollback_on_error(){
    local rc=$?
    trap - ERR
    if [[ "$mutated" == "1" ]]; then
      echo "ERROR after mutation — auto-rolling back v0.002 candidate" >&2
      restore "$backup" || true
    fi
    exit "$rc"
  }
  trap rollback_on_error ERR

  echo
  echo "=== DEPLOY v0.002 ROOT-BROWSE CANDIDATE ==="
  docker stop "$C" >/dev/null
  mutated=1
  docker cp "$CANDIDATE" "$C:$LIVE_DLL" >/dev/null
  docker start "$C" >/dev/null
  sleep 10
  [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer failed to return"
  [[ "$(live_hash)" == "$new" ]] || fail "post-start DLL hash mismatch"
  [[ "$(mega_rows)" == "0" ]] || fail "DB changed during deployment"
  [[ "$(mega_maps)" == "0" ]] || fail "MEGA mappings appeared during deployment"

  cat > "$STATE" <<EOF
backup=$backup
old_dll=$EXPECTED_LIVE
new_dll=$new
installed=$stamp
EOF
  chmod 600 "$STATE"
  trap - ERR
  mutated=0

  echo
  echo "============================================================"
  echo " PASS — v0.002 ROOT-BROWSE CANDIDATE DEPLOYED"
  echo "============================================================"
  echo "Live DLL : $(live_hash)"
  echo "Mega rows: $(mega_rows)"
  echo "Mega maps: $(mega_maps)"
  echo "Backup   : $backup"
  echo "Next     : create ONE fresh MEGA S4 test connection and click its root"
  echo "============================================================"
}

status(){
  echo "Live DLL : $(live_hash 2>/dev/null || echo unavailable)"
  echo "Mega rows: $(mega_rows 2>/dev/null || echo unavailable)"
  echo "Mega maps: $(mega_maps 2>/dev/null || echo unavailable)"
  [[ -s "$STATE" ]] && cat "$STATE"
}

rollback(){
  [[ -s "$STATE" ]] || fail "no v0.002 state file"
  [[ "$(mega_rows)" == "0" ]] || fail "delete the MEGA test connection before rollback"
  [[ "$(mega_maps)" == "0" ]] || fail "MEGA mappings exist; inspect before rollback"
  local backup
  backup="$(sed -n 's/^backup=//p' "$STATE" | head -n1)"
  [[ -d "$backup" ]] || fail "recorded backup missing: $backup"
  restore "$backup"
  rm -f "$STATE"
  echo "PASS: rolled back to previous live DLL"
}

case "$MODE" in
  preflight) preflight ;;
  build) build_candidate ;;
  install) install ;;
  status) status ;;
  rollback) rollback ;;
  *) echo "Usage: $0 {preflight|build|install|status|rollback}" >&2; exit 2 ;;
esac
