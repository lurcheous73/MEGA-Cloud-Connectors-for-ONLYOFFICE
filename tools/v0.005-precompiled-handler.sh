#!/usr/bin/env bash
set -Eeuo pipefail

# BRIMSTONE CUSTOM CODE — install the MEGA S4 helper as a native precompiled ASP.NET handler.
#
# WHY:
#   ONLYOFFICE CommunityServer is a precompiled ASP.NET application. Mono scans bin/*.compiled
#   at application startup and maps resultType=2 virtual paths directly to compiled handler types.
#   A source .ashx makes Mono's SimpleWebHandlerParser attempt dynamic compilation, which fails on
#   this image while resolving System.Runtime. This installer replaces only the Brimstone .ashx
#   source stub with the stock 86-byte precompilation marker and adds one Brimstone .compiled file.
#
# It does NOT alter ASC.Files.Thirdparty.dll, Web.config, the database, or the Files UI bundle.

REPO="${REPO:-/opt/mega-cloud-connectors-for-onlyoffice}"
C="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
DB="${MYSQL_CONTAINER:-onlyoffice-mysql-server}"
EXPECTED_IMAGE="onlyoffice/communityserver:12.8.0.1971"
EXPECTED_DLL="62bdff5b75ab9db37108a6f772a92240805879f0cf400bb8c2813d2aa68b679f"
LIVE_DLL="/var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll"
RUN="/app/run-community-server.sh"
WEB="/var/www/onlyoffice/WebStudio/Web.config"
PRECOMPILED="/var/www/onlyoffice/WebStudio/PrecompiledApp.config"
HANDLER="/var/www/onlyoffice/WebStudio/Products/Files/HttpHandlers/brimstone-megas4.ashx"
BIN="/var/www/onlyoffice/WebStudio/bin"
COMPILED="$BIN/brimstone-megas4.ashx.brimstone.compiled"
VP="/Products/Files/HttpHandlers/brimstone-megas4.ashx"
MAP_PATH="Products/Files/HttpHandlers/brimstone-megas4.ashx"
TYPE="ASC.Files.Thirdparty.MegaS4.BrimstoneMegaS4Handler"
ASSEMBLY="ASC.Files.Thirdparty"
MARKER_ASSET="$REPO/src/mega-s4/communityserver-12.8/ui/brimstone-megas4.marker"
COMPILED_ASSET="$REPO/src/mega-s4/communityserver-12.8/ui/brimstone-megas4.ashx.brimstone.compiled"
STOCK_MARKER="/var/www/onlyoffice/WebStudio/Products/Files/HttpHandlers/thirdpartyapphandler.ashx"
STOCK_COMPILED="$BIN/thirdpartyapphandler.ashx.7edb1b4a.compiled"
BACKUP_ROOT="/var/backups/mega-cloud-connectors-for-onlyoffice"
SOURCE_HANDLER_SHA="b965422c50d04294e8e1d446e397dfd6fa3477b531b0df0bd179d670d8861b44"
STOCK_MARKER_SHA="24fce7c547069682c963ad5bdddc3b597df0f6dc02b663e7f243a85f4ba23f9a"

fail(){ echo "FAIL: $*" >&2; exit 1; }
branch(){ git -C "$REPO" rev-parse --abbrev-ref HEAD; }
worktree_clean(){ [[ -z "$(git -C "$REPO" status --porcelain)" ]]; }
live_dll_hash(){ docker exec "$C" sha256sum "$LIVE_DLL" | awk '{print $1}'; }
handler_hash(){ docker exec "$C" sha256sum "$HANDLER" 2>/dev/null | awk '{print $1}' || true; }
mysql_restarts(){ docker inspect -f '{{.RestartCount}}' "$DB"; }
mysql_started(){ docker inspect -f '{{.State.StartedAt}}' "$DB"; }
mysql_safe_count(){ docker exec "$C" sh -lc "grep -Ec '^[[:space:]]*mysqladmin --no-defaults --protocol=socket --socket=/var/run/mysqld/mysqld.sock shutdown \\|\\| true[[:space:]]*$' '$RUN' || true"; }
web_map_count(){ docker exec "$C" sh -lc "grep -Fc 'path=\"$MAP_PATH\"' '$WEB' || true"; }
compiled_ref_count(){ docker exec "$C" sh -lc "find '$BIN' -maxdepth 1 -type f -name '*.compiled' -exec grep -lF '$VP' {} + 2>/dev/null | wc -l" | tr -d '[:space:]'; }

wait_ready(){
  local label="${1:-CommunityServer}" deadline=$((SECONDS + 240)) elapsed body http
  while (( SECONDS < deadline )); do
    elapsed=$((240 - (deadline - SECONDS)))
    body="$(docker exec "$C" sh -lc 'curl -sS -m 5 http://127.0.0.1/api/2.0/warmup/progress.json 2>/dev/null || true')"
    if printf '%s' "$body" | grep -Eq '"Completed"[[:space:]]*:[[:space:]]*true|\\"Completed\\"[[:space:]]*:[[:space:]]*true'; then
      echo "PASS: $label warmup completed after ${elapsed}s"
      return 0
    fi
    if (( elapsed > 0 && elapsed % 30 == 0 )); then
      http="$(docker exec "$C" sh -lc 'curl -sS -m 5 -o /dev/null -w "%{http_code}" http://127.0.0.1/api/2.0/capabilities.json 2>/dev/null || true')"
      echo "INFO: ${elapsed}s — $label still warming (capabilities HTTP ${http:-000})"
    fi
    sleep 3
  done
  return 1
}

validate_compiled_asset(){
  python3 - "$COMPILED_ASSET" "$VP" "$ASSEMBLY" "$TYPE" <<'PY'
import sys, xml.etree.ElementTree as ET
path, vp, assembly, typ = sys.argv[1:]
root = ET.parse(path).getroot()
assert root.tag == 'preserve', root.tag
assert root.attrib.get('resultType') == '2', root.attrib
assert root.attrib.get('virtualPath') == vp, root.attrib
assert root.attrib.get('assembly') == assembly, root.attrib
assert root.attrib.get('type') == typ, root.attrib
fd = root.find('./filedeps/filedep')
assert fd is not None and fd.attrib.get('name') == vp
print('PASS: Brimstone .compiled metadata validates')
PY
}

preflight_common(){
  [[ -d "$REPO/.git" ]] || fail "repo missing: $REPO"
  [[ "$(branch)" == "v0.005-typed-creds" ]] || fail "checkout v0.005-typed-creds first"
  worktree_clean || fail "repo worktree is not clean"
  command -v python3 >/dev/null 2>&1 || fail "host python3 is required"
  docker inspect "$C" >/dev/null 2>&1 || fail "CommunityServer container missing"
  docker inspect "$DB" >/dev/null 2>&1 || fail "MySQL container missing"
  [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer is not running"
  [[ "$(docker inspect -f '{{.State.Running}}' "$DB")" == "true" ]] || fail "MySQL is not running"
  [[ "$(docker inspect -f '{{.Config.Image}}' "$C")" == "$EXPECTED_IMAGE" ]] || fail "unexpected CommunityServer image"
  [[ "$(live_dll_hash)" == "$EXPECTED_DLL" ]] || fail "live connector DLL is not the locked baseline"
  [[ "$(mysql_safe_count)" == "2" ]] || fail "external-MySQL restart protection is not installed"
  [[ "$(web_map_count)" == "0" ]] || fail "temporary Web.config handler mapping still present; refusing precompiled install"
  docker exec "$C" test -s "$PRECOMPILED" || fail "PrecompiledApp.config missing"
  docker exec "$C" grep -Fq '<precompiledApp' "$PRECOMPILED" || fail "invalid PrecompiledApp.config"
  docker exec "$C" test -s "$HANDLER" || fail "Brimstone physical handler missing"
  docker exec "$C" test -s "$STOCK_MARKER" || fail "stock handler marker missing"
  docker exec "$C" test -s "$STOCK_COMPILED" || fail "stock .compiled template missing"
  [[ -s "$MARKER_ASSET" ]] || fail "repo marker asset missing"
  [[ -s "$COMPILED_ASSET" ]] || fail "repo .compiled asset missing"
  [[ "$(sha256sum "$MARKER_ASSET" | awk '{print $1}')" == "$STOCK_MARKER_SHA" ]] || fail "repo marker asset is not byte-identical to stock marker"
  [[ "$(docker exec "$C" sha256sum "$STOCK_MARKER" | awk '{print $1}')" == "$STOCK_MARKER_SHA" ]] || fail "live stock marker hash differs from proven template"
  validate_compiled_asset
}

preflight(){
  preflight_common
  local hh refs custom
  hh="$(handler_hash)"
  refs="$(compiled_ref_count)"
  custom="no"; docker exec "$C" test -f "$COMPILED" && custom="yes" || true

  echo "============================================================"
  echo " BRIMSTONE v0.005 — PRECOMPILED HANDLER PRE-FLIGHT"
  echo "============================================================"
  echo "Community image : $EXPECTED_IMAGE"
  echo "Connector DLL   : $(live_dll_hash)"
  echo "handler SHA     : $hh"
  echo "stock marker SHA: $STOCK_MARKER_SHA"
  echo "compiled refs   : $refs"
  echo "custom metadata : $custom"
  echo "Web.config map  : $(web_map_count)"
  echo "MySQL safe calls: $(mysql_safe_count)"

  if [[ "$hh" == "$SOURCE_HANDLER_SHA" && "$refs" == "0" && "$custom" == "no" ]]; then
    echo "PASS: exact source-ASHX baseline detected"
    return 0
  fi
  if [[ "$hh" == "$STOCK_MARKER_SHA" && "$refs" == "1" && "$custom" == "yes" ]]; then
    echo "PASS: Brimstone precompiled handler already installed"
    return 0
  fi
  fail "unexpected handler/precompiled state; refusing to continue"
}

install(){
  preflight_common
  [[ "$(handler_hash)" == "$SOURCE_HANDLER_SHA" ]] || fail "physical Brimstone handler is not the exact source baseline"
  [[ "$(compiled_ref_count)" == "0" ]] || fail "a .compiled file already references the Brimstone virtual path"
  docker exec "$C" test ! -e "$COMPILED" || fail "custom Brimstone .compiled file already exists"

  local stamp backup huid hgid hmode cuid cgid cmode
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="$BACKUP_ROOT/brimstone-precompiled-handler-$stamp"
  mkdir -p "$backup"

  docker cp "$C:$HANDLER" "$backup/brimstone-megas4.ashx" >/dev/null
  docker exec "$C" stat -c '%u %g %a' "$HANDLER" > "$backup/handler.stat"
  sha256sum "$backup/brimstone-megas4.ashx" > "$backup/SHA256SUMS"
  printf '%s\n' "$COMPILED" > "$backup/compiled.path"

  read -r huid hgid hmode < <(docker exec "$C" stat -c '%u %g %a' "$STOCK_MARKER")
  read -r cuid cgid cmode < <(docker exec "$C" stat -c '%u %g %a' "$STOCK_COMPILED")

  docker cp "$MARKER_ASSET" "$C:/tmp/brimstone-megas4.marker" >/dev/null
  docker exec "$C" install -o "$huid" -g "$hgid" -m "$hmode" /tmp/brimstone-megas4.marker "$HANDLER"
  docker exec "$C" rm -f /tmp/brimstone-megas4.marker

  docker cp "$COMPILED_ASSET" "$C:/tmp/brimstone-megas4.compiled" >/dev/null
  docker exec "$C" install -o "$cuid" -g "$cgid" -m "$cmode" /tmp/brimstone-megas4.compiled "$COMPILED"
  docker exec "$C" rm -f /tmp/brimstone-megas4.compiled

  [[ "$(handler_hash)" == "$STOCK_MARKER_SHA" ]] || fail "installed physical marker does not match stock marker"
  docker exec "$C" test -s "$COMPILED" || fail "custom .compiled metadata missing after install"
  [[ "$(compiled_ref_count)" == "1" ]] || fail "expected exactly one Brimstone precompiled virtual-path record"
  [[ "$(live_dll_hash)" == "$EXPECTED_DLL" ]] || fail "connector DLL changed unexpectedly"

  echo "============================================================"
  echo " INSTALLED — NO RESTART PERFORMED"
  echo "============================================================"
  echo "Backup             : $backup"
  echo "Physical ASHX      : stock precompilation marker"
  echo "Precompiled record : $COMPILED"
  echo "Web.config mapping : $(web_map_count)"
  echo "Connector DLL      : $(live_dll_hash)"
  echo "MySQL restarts     : $(mysql_restarts)"
  echo "Next: '$0 test' performs one controlled CommunityServer restart and route probe."
}

status(){
  preflight_common
  local custom="no"
  docker exec "$C" test -f "$COMPILED" && custom="yes" || true
  echo "============================================================"
  echo " BRIMSTONE v0.005 — PRECOMPILED HANDLER STATUS"
  echo "============================================================"
  echo "Connector DLL   : $(live_dll_hash)"
  echo "MySQL restarts  : $(mysql_restarts)"
  echo "handler SHA     : $(handler_hash)"
  echo "compiled refs   : $(compiled_ref_count)"
  echo "custom metadata : $custom"
  echo "Web.config map  : $(web_map_count)"
  echo "MySQL safe calls: $(mysql_safe_count)"
  echo
  if docker exec "$C" test -f "$COMPILED"; then
    docker exec "$C" cat "$COMPILED"
  fi
}

rollback(){
  preflight_common
  local backup uid gid mode before started
  backup="$(find "$BACKUP_ROOT" -maxdepth 1 -type d -name 'brimstone-precompiled-handler-*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1{$1=""; sub(/^ /,""); print; exit}')"
  [[ -n "$backup" && -s "$backup/brimstone-megas4.ashx" && -s "$backup/handler.stat" ]] || fail "no valid precompiled-handler backup found"
  (cd "$backup" && sha256sum -c SHA256SUMS >/dev/null) || fail "handler backup checksum failed"
  [[ "$(sha256sum "$backup/brimstone-megas4.ashx" | awk '{print $1}')" == "$SOURCE_HANDLER_SHA" ]] || fail "backup is not the exact source handler baseline"

  read -r uid gid mode < "$backup/handler.stat"
  before="$(mysql_restarts)"
  started="$(mysql_started)"

  docker exec "$C" rm -f "$COMPILED"
  docker cp "$backup/brimstone-megas4.ashx" "$C:/tmp/brimstone-megas4.rollback" >/dev/null
  docker exec "$C" install -o "$uid" -g "$gid" -m "$mode" /tmp/brimstone-megas4.rollback "$HANDLER"
  docker exec "$C" rm -f /tmp/brimstone-megas4.rollback

  [[ "$(handler_hash)" == "$SOURCE_HANDLER_SHA" ]] || fail "rollback physical handler hash mismatch"
  [[ "$(compiled_ref_count)" == "0" ]] || fail "Brimstone .compiled reference remains after rollback"

  echo "Restarting CommunityServer only to clear the precompiled type cache..."
  docker restart "$C" >/dev/null
  wait_ready "rolled-back CommunityServer" || fail "rolled-back CommunityServer did not complete warmup"

  [[ "$(mysql_restarts)" == "$before" ]] || fail "MySQL restart count changed during rollback"
  [[ "$(mysql_started)" == "$started" ]] || fail "MySQL StartedAt changed during rollback"
  [[ "$(live_dll_hash)" == "$EXPECTED_DLL" ]] || fail "connector DLL changed during rollback"

  echo "============================================================"
  echo " ROLLBACK COMPLETE"
  echo "============================================================"
  echo "Restored handler SHA: $(handler_hash)"
  echo "compiled refs       : $(compiled_ref_count)"
  echo "MySQL restarts      : $(mysql_restarts)"
  echo "Connector DLL       : $(live_dll_hash)"
}

test_restart(){
  preflight_common
  [[ "$(handler_hash)" == "$STOCK_MARKER_SHA" ]] || fail "Brimstone physical file is not the stock precompilation marker"
  docker exec "$C" test -s "$COMPILED" || fail "custom .compiled metadata is not installed"
  [[ "$(compiled_ref_count)" == "1" ]] || fail "expected exactly one Brimstone precompiled virtual-path record"

  local before started after code headers body
  before="$(mysql_restarts)"
  started="$(mysql_started)"

  echo "============================================================"
  echo " CONTROLLED PRECOMPILED-HANDLER TEST"
  echo "============================================================"
  echo "MySQL restart count before: $before"
  echo "MySQL StartedAt before     : $started"
  echo "Restarting CommunityServer only..."
  docker restart "$C" >/dev/null

  if ! wait_ready "precompiled-handler CommunityServer"; then
    echo "FAIL: CommunityServer did not complete warmup; rolling back"
    rollback || true
    return 1
  fi

  after="$(mysql_restarts)"
  if [[ "$after" != "$before" || "$(mysql_started)" != "$started" ]]; then
    echo "FAIL: MySQL state changed during test; rolling back"
    rollback || true
    return 1
  fi
  [[ "$(live_dll_hash)" == "$EXPECTED_DLL" ]] || { echo "FAIL: connector DLL changed"; rollback || true; return 1; }

  headers="$(mktemp)"
  body="$(mktemp)"
  trap 'rm -f "$headers" "$body"' RETURN

  code="$(docker exec "$C" sh -lc "curl -sS -D /tmp/brimstone-precompiled.headers -o /tmp/brimstone-precompiled.body -w '%{http_code}' -X POST --data-urlencode 'action=list-buckets' --data-urlencode 'source=manual' --data-urlencode 'accessKey=x' --data-urlencode 'secretKey=y' 'http://127.0.0.1$VP' || true")"
  docker cp "$C:/tmp/brimstone-precompiled.headers" "$headers" >/dev/null 2>&1 || true
  docker cp "$C:/tmp/brimstone-precompiled.body" "$body" >/dev/null 2>&1 || true
  docker exec "$C" rm -f /tmp/brimstone-precompiled.headers /tmp/brimstone-precompiled.body >/dev/null 2>&1 || true

  echo "Route probe HTTP: ${code:-unknown}"
  echo "--- headers ---"
  sed -n '1,30p' "$headers" 2>/dev/null || true
  echo "--- body ---"
  sed -n '1,50p' "$body" 2>/dev/null || true

  if grep -Fq 'System.Web.Compilation.ParseException' "$body" 2>/dev/null \
     || grep -Fq 'System.Runtime, Version=4.0.0.0' "$body" 2>/dev/null \
     || grep -Fq '<%@ WebHandler' "$body" 2>/dev/null \
     || grep -Fq 'marker file generated by the precompilation tool' "$body" 2>/dev/null; then
    echo "FAIL: request still entered the physical/dynamic ASHX parser; rolling back"
    rollback || true
    return 1
  fi

  if grep -Fq 'BRIMSTONE MEGA S4 handler error:' "$body" 2>/dev/null \
     || grep -Fq 'Authentication required.' "$body" 2>/dev/null \
     || grep -Fq '"ok":' "$body" 2>/dev/null; then
    echo "PASS: Brimstone compiled handler executed"
  elif [[ "$code" =~ ^(200|302|401|403|405)$ ]]; then
    echo "PASS: precompiled route resolved without dynamic parser failure (HTTP $code)"
  else
    echo "FAIL: unexpected non-Brimstone route response HTTP ${code:-unknown}; rolling back"
    rollback || true
    return 1
  fi

  echo "PASS: dynamic System.Runtime parser failure eliminated"
  echo "PASS: MySQL restart count remains $before"
  echo "PASS: MySQL StartedAt unchanged"
  echo "PASS: Connector DLL remains $(live_dll_hash)"
  echo "Precompiled handler remains installed for authenticated Files UI testing."
}

case "${1:-status}" in
  preflight) preflight ;;
  install) install ;;
  status) status ;;
  test) test_restart ;;
  rollback) rollback ;;
  *) echo "Usage: $0 {preflight|install|status|test|rollback}" >&2; exit 2 ;;
esac
