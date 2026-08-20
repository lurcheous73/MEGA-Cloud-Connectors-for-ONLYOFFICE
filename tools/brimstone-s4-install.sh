#!/usr/bin/env bash
# BRIMSTONE CUSTOM CODE — canonical production installer for Brimstone MEGA S4.
# Builds the shared S4 + MEGA Cloud DLL, installs the accepted Safari-safe UI,
# installs the browser-accepted S4 source-handler + precompiled mapping, protects
# external MySQL, and rolls back the connector runtime atomically on failure.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tools/lib/brimstone-connectors-common.sh
source "$ROOT/tools/lib/brimstone-connectors-common.sh"

VERSION="2026.08.20-working-2"
BUILDER="$ROOT/tools/brimstone-build-combined.sh"
STATE_FILE="$BRIMSTONE_STATE_ROOT/s4-current.env"
STOCK_COMPILED="/var/www/onlyoffice/WebStudio/bin/thirdpartyapphandler.ashx.7edb1b4a.compiled"

fail(){ brimstone_fail "$@"; exit 1; }

runtime_backup(){
  local backup="$1" list compiled_present=0 p
  mkdir -p "$backup"
  list="${BRIMSTONE_LIVE_DLL#/} ${BRIMSTONE_HANDLER#/}"
  if docker exec "$BRIMSTONE_CONTAINER" test -e "$BRIMSTONE_COMPILED"; then
    compiled_present=1
    list+=" ${BRIMSTONE_COMPILED#/}"
  fi
  for p in "${BRIMSTONE_UI_PATHS[@]}"; do
    docker exec "$BRIMSTONE_CONTAINER" test -s "$p" || fail "required UI runtime file missing: $p"
    list+=" ${p#/}"
    if docker exec "$BRIMSTONE_CONTAINER" test -e "$p.gz"; then list+=" ${p#/}.gz"; fi
  done
  docker exec "$BRIMSTONE_CONTAINER" sh -lc "tar -C / -cpf /tmp/brimstone-s4-runtime-backup.tar $list"
  docker cp "$BRIMSTONE_CONTAINER:/tmp/brimstone-s4-runtime-backup.tar" "$backup/runtime.tar" >/dev/null
  docker exec "$BRIMSTONE_CONTAINER" rm -f /tmp/brimstone-s4-runtime-backup.tar
  sha256sum "$backup/runtime.tar" > "$backup/runtime.tar.sha256"
  cat > "$backup/runtime.env" <<EOF
compiled_present=$compiled_present
before_dll_sha=$(brimstone_live_sha "$BRIMSTONE_LIVE_DLL")
repo_commit=$(git -C "$ROOT" rev-parse HEAD)
installer_version=$VERSION
EOF
  echo "PASS: runtime backup created: $backup"
}

restore_runtime_backup(){
  local backup="$1" compiled_present db_before
  [[ -s "$backup/runtime.tar" && -s "$backup/runtime.tar.sha256" && -s "$backup/runtime.env" ]] || fail "invalid runtime backup: $backup"
  (cd "$backup" && sha256sum -c runtime.tar.sha256 >/dev/null) || fail "runtime backup checksum failed"
  # shellcheck disable=SC1090
  source "$backup/runtime.env"
  db_before="$(brimstone_mysql_snapshot)"
  docker cp "$backup/runtime.tar" "$BRIMSTONE_CONTAINER:/tmp/brimstone-s4-runtime-rollback.tar" >/dev/null
  docker exec "$BRIMSTONE_CONTAINER" tar -C / -xpf /tmp/brimstone-s4-runtime-rollback.tar
  docker exec "$BRIMSTONE_CONTAINER" rm -f /tmp/brimstone-s4-runtime-rollback.tar
  if [[ "$compiled_present" == "0" ]]; then docker exec "$BRIMSTONE_CONTAINER" rm -f "$BRIMSTONE_COMPILED"; fi
  echo "Restarting CommunityServer only after rollback..."
  docker restart "$BRIMSTONE_CONTAINER" >/dev/null
  brimstone_wait_ready || fail "rolled-back CommunityServer did not become ready"
  brimstone_mysql_assert_snapshot "$db_before" || fail "MySQL changed during rollback"
  echo "PASS: connector runtime restored from $backup"
}

validate_compiled_asset(){
  [[ -s "$BRIMSTONE_HANDLER_COMPILED_ASSET" ]] || fail "compiled handler asset missing"
  python3 - "$BRIMSTONE_HANDLER_COMPILED_ASSET" "$BRIMSTONE_HANDLER_VPATH" <<'PY'
import sys, xml.etree.ElementTree as ET
path,vp=sys.argv[1:]
r=ET.parse(path).getroot()
assert r.tag=='preserve'
assert r.attrib.get('resultType')=='2'
assert r.attrib.get('virtualPath')==vp
assert r.attrib.get('assembly')=='ASC.Files.Thirdparty'
assert r.attrib.get('type')=='ASC.Files.Thirdparty.MegaS4.BrimstoneMegaS4Handler'
fd=r.find('./filedeps/filedep')
assert fd is not None and fd.attrib.get('name')==vp
print('PASS: precompiled S4 handler metadata validates')
PY
}

install_handler(){
  local huid hgid hmode cuid cgid cmode
  [[ "$(brimstone_web_map_count)" == "0" ]] || fail "temporary Web.config S4 handler mapping exists"
  [[ "$(brimstone_handler_ref_count)" =~ ^[01]$ ]] || fail "unexpected number of precompiled S4 handler references"
  [[ -s "$BRIMSTONE_HANDLER_SOURCE_ASSET" ]] || fail "accepted S4 source-handler asset missing"
  [[ "$(brimstone_sha "$BRIMSTONE_HANDLER_SOURCE_ASSET")" == "$BRIMSTONE_HANDLER_SOURCE_SHA" ]] || fail "accepted S4 source-handler hash mismatch"
  docker exec "$BRIMSTONE_CONTAINER" test -s "$STOCK_COMPILED" || fail "stock .compiled permissions template missing"
  validate_compiled_asset

  if docker exec "$BRIMSTONE_CONTAINER" test -e "$BRIMSTONE_HANDLER"; then
    read -r huid hgid hmode < <(docker exec "$BRIMSTONE_CONTAINER" stat -c '%u %g %a' "$BRIMSTONE_HANDLER")
  else
    read -r huid hgid hmode < <(docker exec "$BRIMSTONE_CONTAINER" stat -c '%u %g %a' "$BRIMSTONE_STOCK_MARKER")
  fi

  if docker exec "$BRIMSTONE_CONTAINER" test -e "$BRIMSTONE_COMPILED"; then
    read -r cuid cgid cmode < <(docker exec "$BRIMSTONE_CONTAINER" stat -c '%u %g %a' "$BRIMSTONE_COMPILED")
  else
    read -r cuid cgid cmode < <(docker exec "$BRIMSTONE_CONTAINER" stat -c '%u %g %a' "$STOCK_COMPILED")
  fi

  docker cp "$BRIMSTONE_HANDLER_SOURCE_ASSET" "$BRIMSTONE_CONTAINER:/tmp/brimstone-megas4.ashx" >/dev/null
  docker exec "$BRIMSTONE_CONTAINER" install -o "$huid" -g "$hgid" -m "$hmode" /tmp/brimstone-megas4.ashx "$BRIMSTONE_HANDLER"
  docker cp "$BRIMSTONE_HANDLER_COMPILED_ASSET" "$BRIMSTONE_CONTAINER:/tmp/brimstone-megas4.compiled" >/dev/null
  docker exec "$BRIMSTONE_CONTAINER" install -o "$cuid" -g "$cgid" -m "$cmode" /tmp/brimstone-megas4.compiled "$BRIMSTONE_COMPILED"
  docker exec "$BRIMSTONE_CONTAINER" rm -f /tmp/brimstone-megas4.ashx /tmp/brimstone-megas4.compiled

  [[ "$(brimstone_live_sha "$BRIMSTONE_HANDLER")" == "$BRIMSTONE_HANDLER_SOURCE_SHA" ]] || fail "installed S4 source-handler hash mismatch"
  [[ "$(brimstone_handler_ref_count)" == "1" ]] || fail "expected exactly one precompiled S4 handler reference"
  echo "PASS: browser-accepted S4 source-handler + precompiled mapping installed"
}

patch_ui_file(){
  local path="$1" src patched uid gid mode gz gzout guid ggid gmode
  src="$(mktemp)"; patched="$(mktemp)"
  docker cp "$BRIMSTONE_CONTAINER:$path" "$src" >/dev/null
  python3 - "$src" "$BRIMSTONE_UI_ASSET" "$patched" <<'PY'
from pathlib import Path
import sys
src,asset,dst=map(Path,sys.argv[1:])
s=src.read_text()
a=asset.read_text()
marker='/* MEGA S4 LIVE EXTENSION v1'
i=s.find(marker)
if i >= 0:
    base=s[:i].rstrip()
else:
    base=s.rstrip()
out=base+'\n\n'+a
Path(dst).write_text(out)
PY
  read -r uid gid mode < <(docker exec "$BRIMSTONE_CONTAINER" stat -c '%u %g %a' "$path")
  docker cp "$patched" "$BRIMSTONE_CONTAINER:/tmp/brimstone-ui.js" >/dev/null
  docker exec "$BRIMSTONE_CONTAINER" install -o "$uid" -g "$gid" -m "$mode" /tmp/brimstone-ui.js "$path"
  docker exec "$BRIMSTONE_CONTAINER" rm -f /tmp/brimstone-ui.js

  gz="$path.gz"
  if docker exec "$BRIMSTONE_CONTAINER" test -e "$gz"; then
    gzout="$(mktemp)"
    gzip -n -c "$patched" > "$gzout"
    read -r guid ggid gmode < <(docker exec "$BRIMSTONE_CONTAINER" stat -c '%u %g %a' "$gz")
    docker cp "$gzout" "$BRIMSTONE_CONTAINER:/tmp/brimstone-ui.js.gz" >/dev/null
    docker exec "$BRIMSTONE_CONTAINER" install -o "$guid" -g "$ggid" -m "$gmode" /tmp/brimstone-ui.js.gz "$gz"
    docker exec "$BRIMSTONE_CONTAINER" rm -f /tmp/brimstone-ui.js.gz
    rm -f "$gzout"
  fi
  rm -f "$src" "$patched"
  [[ "$(brimstone_live_ui_tail_hash "$path")" == "$BRIMSTONE_UI_SHA" ]] || fail "accepted UI tail hash mismatch after patch: $path"
  echo "PASS: accepted Safari-safe UI installed: $path"
}

install_ui(){
  local p
  brimstone_validate_ui_asset || fail "accepted UI asset failed validation"
  for p in "${BRIMSTONE_UI_PATHS[@]}"; do patch_ui_file "$p"; done
}

deploy_dll(){
  local candidate="$1" uid gid mode expected staged
  expected="$(brimstone_sha "$candidate")"
  read -r uid gid mode < <(docker exec "$BRIMSTONE_CONTAINER" stat -c '%u %g %a' "$BRIMSTONE_LIVE_DLL")
  docker cp "$candidate" "$BRIMSTONE_CONTAINER:/tmp/ASC.Files.Thirdparty.brimstone.dll" >/dev/null
  staged="$(brimstone_live_sha /tmp/ASC.Files.Thirdparty.brimstone.dll)"
  [[ "$staged" == "$expected" ]] || fail "staged combined DLL hash mismatch"
  docker exec "$BRIMSTONE_CONTAINER" install -o "$uid" -g "$gid" -m "$mode" /tmp/ASC.Files.Thirdparty.brimstone.dll "$BRIMSTONE_LIVE_DLL"
  docker exec "$BRIMSTONE_CONTAINER" rm -f /tmp/ASC.Files.Thirdparty.brimstone.dll
  [[ "$(brimstone_live_sha "$BRIMSTONE_LIVE_DLL")" == "$expected" ]] || fail "live combined DLL hash mismatch after install"
  echo "PASS: combined S4 + MEGA Cloud DLL installed: $expected"
}

route_probe(){
  local body code
  body="$(mktemp)"
  code="$(docker exec "$BRIMSTONE_CONTAINER" sh -lc "curl -sS -m 20 -o /tmp/brimstone-s4-probe.body -w '%{http_code}' -X POST --data-urlencode 'action=list-buckets' --data-urlencode 'source=manual' --data-urlencode 'accessKey=x' --data-urlencode 'secretKey=y' 'http://127.0.0.1$BRIMSTONE_HANDLER_VPATH' || true")"
  docker cp "$BRIMSTONE_CONTAINER:/tmp/brimstone-s4-probe.body" "$body" >/dev/null 2>&1 || true
  docker exec "$BRIMSTONE_CONTAINER" rm -f /tmp/brimstone-s4-probe.body >/dev/null 2>&1 || true
  if grep -Fq 'System.Web.Compilation.ParseException' "$body" 2>/dev/null || grep -Fq '<%@ WebHandler' "$body" 2>/dev/null || grep -Fq 'marker file generated by the precompilation tool' "$body" 2>/dev/null; then
    rm -f "$body"; fail "S4 route entered dynamic/physical ASHX parser"
  fi
  if grep -Fq 'BRIMSTONE MEGA S4 handler error:' "$body" 2>/dev/null || grep -Fq 'Authentication required.' "$body" 2>/dev/null || grep -Fq '"ok":' "$body" 2>/dev/null || [[ "$code" =~ ^(200|302|401|403|405)$ ]]; then
    echo "PASS: precompiled S4 route resolved (HTTP ${code:-unknown})"
    rm -f "$body"; return 0
  fi
  rm -f "$body"; fail "unexpected S4 route response HTTP ${code:-unknown}"
}

verify_mysql_state_readonly(){
  local host p s
  host="$(brimstone_mysql_host)"
  p="$(brimstone_mysql_plain_count)"
  s="$(brimstone_mysql_safe_count)"
  [[ "$host" == "onlyoffice-mysql-server" ]] || fail "root.cnf is not targeting onlyoffice-mysql-server"

  if [[ "$p" == "0" && "$s" =~ ^[1-9][0-9]*$ ]]; then
    echo "PASS: external-MySQL restart protection active ($s guarded call(s))"
    return 0
  fi

  if [[ "$p" =~ ^[1-9][0-9]*$ && "$s" == "0" ]]; then
    echo "INFO: external-MySQL protection pending; install will patch $p exact plain shutdown call(s)"
    return 0
  fi

  fail "unexpected CommunityServer mysqladmin state: plain=$p safe=$s"
}

verify(){
  local p before
  brimstone_repo_preflight || return 1
  brimstone_platform_preflight || return 1
  before="$(brimstone_mysql_snapshot)"
  verify_mysql_state_readonly
  brimstone_validate_live_dll || fail "live combined DLL contract failed"
  [[ "$(brimstone_live_sha "$BRIMSTONE_HANDLER")" == "$BRIMSTONE_HANDLER_SOURCE_SHA" ]] || fail "S4 physical handler is not the browser-accepted source directive"
  docker exec "$BRIMSTONE_CONTAINER" test -s "$BRIMSTONE_COMPILED" || fail "S4 .compiled metadata missing"
  [[ "$(brimstone_handler_ref_count)" == "1" ]] || fail "S4 precompiled handler reference count is not one"
  [[ "$(brimstone_web_map_count)" == "0" ]] || fail "obsolete Web.config S4 mapping remains"
  validate_compiled_asset
  for p in "${BRIMSTONE_UI_PATHS[@]}"; do
    [[ "$(brimstone_live_ui_tail_hash "$p")" == "$BRIMSTONE_UI_SHA" ]] || fail "live accepted S4 UI mismatch: $p"
  done
  route_probe
  brimstone_mysql_assert_snapshot "$before" || fail "MySQL changed during read-only verification"
  echo "============================================================"
  echo " PASS — BRIMSTONE MEGA S4 RUNTIME VERIFIED"
  echo "============================================================"
  echo "DLL: $(brimstone_live_sha "$BRIMSTONE_LIVE_DLL")"
  echo "UI : $BRIMSTONE_UI_SHA"
}

status(){
  local p
  brimstone_platform_preflight || return 1
  echo "============================================================"
  echo " BRIMSTONE MEGA S4 STATUS — $VERSION"
  echo "============================================================"
  echo "Repo commit       : $(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "Community image   : $(docker inspect -f '{{.Config.Image}}' "$BRIMSTONE_CONTAINER")"
  echo "Combined DLL      : $(brimstone_live_sha "$BRIMSTONE_LIVE_DLL")"
  echo "MySQL restart     : $(docker inspect -f '{{.RestartCount}}' "$BRIMSTONE_DB_CONTAINER")"
  echo "MySQL plain/safe  : $(brimstone_mysql_plain_count)/$(brimstone_mysql_safe_count)"
  echo "Handler SHA       : $(brimstone_live_sha "$BRIMSTONE_HANDLER" 2>/dev/null || echo missing)"
  echo "Handler refs      : $(brimstone_handler_ref_count)"
  echo "Web.config maps   : $(brimstone_web_map_count)"
  for p in "${BRIMSTONE_UI_PATHS[@]}"; do echo "UI tail $(basename "$p"): $(brimstone_live_ui_tail_hash "$p" 2>/dev/null || echo absent)"; done
  if [[ -s "$STATE_FILE" ]]; then echo "Installer state   : $STATE_FILE"; else echo "Installer state   : none (runtime may pre-date canonical installer)"; fi
}

install(){
  local candidate candidate_sha backup stamp db_before mutated=0
  brimstone_repo_preflight || return 1
  brimstone_platform_preflight || return 1
  [[ -x "$BUILDER" ]] || fail "canonical combined builder is not executable: $BUILDER"
  brimstone_validate_ui_asset || fail "accepted UI asset invalid"

  "$BUILDER" build
  candidate="$("$BUILDER" path)"
  [[ -s "$candidate" ]] || fail "combined candidate missing after build"
  candidate_sha="$(brimstone_sha "$candidate")"

  if brimstone_mysql_protection_ok && [[ "$(brimstone_live_sha "$BRIMSTONE_LIVE_DLL")" == "$candidate_sha" ]] && verify >/dev/null 2>&1; then
    echo "PASS: this exact Brimstone S4 release is already installed and verified"
    echo "DLL: $candidate_sha"
    return 0
  fi

  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="$BRIMSTONE_BACKUP_ROOT/brimstone-s4-release-$stamp"
  db_before="$(brimstone_mysql_snapshot)"
  runtime_backup "$backup"

  rollback_on_error(){
    local rc=$?
    trap - ERR
    if [[ "$mutated" == "1" ]]; then
      echo "BRIMSTONE: install failed — restoring pre-install connector runtime" >&2
      restore_runtime_backup "$backup" || echo "BRIMSTONE FAIL: automatic runtime rollback also failed; backup=$backup" >&2
    fi
    exit "$rc"
  }
  trap rollback_on_error ERR

  # External-MySQL protection is a safety invariant and is intentionally retained
  # even if the connector payload is later rolled back.
  brimstone_install_mysql_protection "$backup"
  brimstone_mysql_protection_ok || fail "external-MySQL protection is not active after patch"
  mutated=1
  deploy_dll "$candidate"
  install_handler
  install_ui
  brimstone_validate_live_dll

  echo "Restarting CommunityServer only..."
  docker restart "$BRIMSTONE_CONTAINER" >/dev/null
  brimstone_wait_ready
  brimstone_mysql_assert_snapshot "$db_before"
  brimstone_mysql_protection_ok || fail "external-MySQL protection was lost during restart"
  verify

  mkdir -p "$BRIMSTONE_STATE_ROOT"
  cat > "$STATE_FILE" <<EOF
installer_version=$VERSION
repo_commit=$(git -C "$ROOT" rev-parse HEAD)
backup_dir=$backup
installed_dll_sha=$candidate_sha
installed_at=$stamp
EOF
  chmod 600 "$STATE_FILE"
  mutated=0
  trap - ERR
  echo "============================================================"
  echo " PASS — BRIMSTONE MEGA S4 INSTALL COMPLETE"
  echo "============================================================"
  echo "DLL    : $candidate_sha"
  echo "Backup : $backup"
  echo "State  : $STATE_FILE"
}

rollback(){
  local backup db_before stamp
  brimstone_platform_preflight || return 1
  [[ -s "$STATE_FILE" ]] || fail "no canonical S4 installer state exists"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  backup="${backup_dir:-}"
  [[ -n "$backup" ]] || fail "state file does not identify a backup"
  # Never reintroduce vulnerable external-MySQL shutdown calls.
  if ! brimstone_mysql_protection_ok; then
    brimstone_install_mysql_protection "$backup"
  fi
  db_before="$(brimstone_mysql_snapshot)"
  restore_runtime_backup "$backup"
  brimstone_mysql_assert_snapshot "$db_before"
  stamp="$(date +%Y%m%d-%H%M%S)"
  mv "$STATE_FILE" "$BRIMSTONE_STATE_ROOT/s4-rolled-back-$stamp.env"
  echo "============================================================"
  echo " ROLLBACK COMPLETE — MYSQL PROTECTION RETAINED"
  echo "============================================================"
  echo "Restored from: $backup"
}

case "${1:-status}" in
  status) status ;;
  verify) verify ;;
  install) install ;;
  rollback) rollback ;;
  *) echo "Usage: $0 {status|verify|install|rollback}" >&2; exit 2 ;;
esac
