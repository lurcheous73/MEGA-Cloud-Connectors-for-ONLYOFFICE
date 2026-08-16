#!/usr/bin/env bash
set -Eeuo pipefail

# BRIMSTONE CUSTOM CODE — map the precompiled MEGA S4 helper handler explicitly.
# CommunityServer is deployed as a precompiled ASP.NET application. Dropping a new
# source .ashx file into Products/Files/HttpHandlers is not enough; the URL must be
# mapped to the already-compiled IHttpHandler type in Web.config.

REPO="${REPO:-/opt/mega-cloud-connectors-for-onlyoffice}"
C="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
DB="${MYSQL_CONTAINER:-onlyoffice-mysql-server}"
WEB="/var/www/onlyoffice/WebStudio/Web.config"
RUN="/app/run-community-server.sh"
HANDLER="/var/www/onlyoffice/WebStudio/Products/Files/HttpHandlers/brimstone-megas4.ashx"
EXPECTED_IMAGE="onlyoffice/communityserver:12.8.0.1971"
EXPECTED_DLL="62bdff5b75ab9db37108a6f772a92240805879f0cf400bb8c2813d2aa68b679f"
LIVE_DLL="/var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll"
BACKUP_ROOT="/var/backups/mega-cloud-connectors-for-onlyoffice"
MAP_PATH='Products/Files/HttpHandlers/brimstone-megas4.ashx'
MAP_LINE='      <add verb="POST" path="Products/Files/HttpHandlers/brimstone-megas4.ashx" type="ASC.Files.Thirdparty.MegaS4.BrimstoneMegaS4Handler, ASC.Files.Thirdparty" />'

fail(){ echo "FAIL: $*" >&2; exit 1; }
branch(){ git -C "$REPO" rev-parse --abbrev-ref HEAD; }
worktree_clean(){ [[ -z "$(git -C "$REPO" status --porcelain)" ]]; }
live_dll_hash(){ docker exec "$C" sha256sum "$LIVE_DLL" | awk '{print $1}'; }
map_path_count(){ docker exec "$C" sh -lc "grep -Fc 'path=\"$MAP_PATH\"' '$WEB' || true"; }
map_exact_count(){ docker exec "$C" sh -lc "grep -Fxc '$MAP_LINE' '$WEB' || true"; }
httphandlers_open_count(){ docker exec "$C" sh -lc "grep -Ec '<httpHandlers([[:space:]]|>)' '$WEB' || true"; }
httphandlers_close_count(){ docker exec "$C" sh -lc "grep -Ec '</httpHandlers>' '$WEB' || true"; }
mysql_safe_count(){ docker exec "$C" sh -lc "grep -Ec '^[[:space:]]*mysqladmin --no-defaults --protocol=socket --socket=/var/run/mysqld/mysqld.sock shutdown \\|\\| true[[:space:]]*$' '$RUN' || true"; }

preflight_common(){
  [[ -d "$REPO/.git" ]] || fail "repo missing: $REPO"
  [[ "$(branch)" == "v0.005-typed-creds" ]] || fail "checkout v0.005-typed-creds first"
  worktree_clean || fail "repo worktree is not clean"
  command -v python3 >/dev/null 2>&1 || fail "host python3 is required for XML-safe patching"
  docker inspect "$C" >/dev/null 2>&1 || fail "CommunityServer container missing"
  docker inspect "$DB" >/dev/null 2>&1 || fail "MySQL container missing"
  [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer is not running"
  [[ "$(docker inspect -f '{{.State.Running}}' "$DB")" == "true" ]] || fail "MySQL is not running"
  [[ "$(docker inspect -f '{{.Config.Image}}' "$C")" == "$EXPECTED_IMAGE" ]] || fail "unexpected CommunityServer image"
  [[ "$(live_dll_hash)" == "$EXPECTED_DLL" ]] || fail "live connector DLL is not the locked v0.004/v0.005 baseline"
  docker exec "$C" test -s "$WEB" || fail "missing live Web.config: $WEB"
  docker exec "$C" test -s "$HANDLER" || fail "missing Brimstone handler marker/source file"
  [[ "$(httphandlers_open_count)" == "1" ]] || fail "expected exactly one <httpHandlers> section"
  [[ "$(httphandlers_close_count)" == "1" ]] || fail "expected exactly one </httpHandlers> section"
}

preflight(){
  preflight_common
  local p e safe
  p="$(map_path_count)"
  e="$(map_exact_count)"
  safe="$(mysql_safe_count)"

  echo "============================================================"
  echo " BRIMSTONE v0.005 — HANDLER MAP PRE-FLIGHT"
  echo "============================================================"
  echo "Community image : $EXPECTED_IMAGE"
  echo "Connector DLL   : $(live_dll_hash)"
  echo "handler path    : $MAP_PATH"
  echo "path mappings   : $p"
  echo "exact mappings  : $e"
  echo "MySQL safe calls: $safe"

  [[ "$safe" == "2" ]] || fail "external-MySQL protection is not proven/installed; refusing handler-map work"
  if [[ "$p" == "0" && "$e" == "0" ]]; then
    echo "PASS: exact unmapped precompiled baseline detected"
    return 0
  fi
  if [[ "$p" == "1" && "$e" == "1" ]]; then
    echo "PASS: Brimstone handler mapping is already installed"
    return 0
  fi
  fail "unexpected Brimstone mapping state; refusing to patch"
}

validate_xml(){
  python3 - "$1" <<'PY'
import sys, xml.etree.ElementTree as ET
ET.parse(sys.argv[1])
print("PASS: XML parses")
PY
}

install(){
  preflight_common
  [[ "$(mysql_safe_count)" == "2" ]] || fail "external-MySQL protection missing"
  [[ "$(map_path_count)" == "0" ]] || fail "Brimstone handler path already mapped or conflicts"
  [[ "$(map_exact_count)" == "0" ]] || fail "Brimstone exact mapping already present"

  local stamp backup src patched uid gid mode
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="$BACKUP_ROOT/brimstone-handler-map-$stamp"
  mkdir -p "$backup"

  docker cp "$C:$WEB" "$backup/Web.config" >/dev/null
  docker cp "$C:$HANDLER" "$backup/brimstone-megas4.ashx" >/dev/null
  sha256sum "$backup/Web.config" "$backup/brimstone-megas4.ashx" > "$backup/SHA256SUMS"

  src="$(mktemp)"
  patched="$(mktemp)"
  trap 'rm -f "$src" "$patched"' RETURN
  docker cp "$C:$WEB" "$src" >/dev/null

  python3 - "$src" "$patched" "$MAP_LINE" <<'PY'
from pathlib import Path
import sys
src, dst, mapping = sys.argv[1:4]
data = Path(src).read_bytes()
needle = b'</httpHandlers>'
if data.count(needle) != 1:
    raise SystemExit('expected exactly one </httpHandlers>')
if b'Products/Files/HttpHandlers/brimstone-megas4.ashx' in data:
    raise SystemExit('Brimstone handler path already exists')
idx = data.index(needle)
line_start = data.rfind(b'\n', 0, idx) + 1
newline = b'\r\n' if b'\r\n' in data else b'\n'
out = data[:line_start] + mapping.encode('utf-8') + newline + data[line_start:]
Path(dst).write_bytes(out)
PY

  validate_xml "$patched"
  [[ "$(grep -Fc "path=\"$MAP_PATH\"" "$patched" || true)" == "1" ]] || fail "patched temp missing exact handler path"
  [[ "$(grep -Fxc "$MAP_LINE" "$patched" || true)" == "1" ]] || fail "patched temp missing exact mapping line"

  read -r uid gid mode < <(docker exec "$C" stat -c '%u %g %a' "$WEB")
  docker cp "$patched" "$C:/tmp/brimstone-Web.config" >/dev/null
  docker exec "$C" install -o "$uid" -g "$gid" -m "$mode" /tmp/brimstone-Web.config "$WEB"
  docker exec "$C" rm -f /tmp/brimstone-Web.config

  [[ "$(map_path_count)" == "1" ]] || fail "live Web.config does not contain exactly one Brimstone handler path"
  [[ "$(map_exact_count)" == "1" ]] || fail "live Web.config does not contain exact Brimstone mapping"

  echo "============================================================"
  echo " INSTALLED — NO EXPLICIT RESTART PERFORMED"
  echo "============================================================"
  echo "Backup: $backup"
  echo "Connector DLL remains: $(live_dll_hash)"
  echo "MySQL restart count: $(docker inspect -f '{{.RestartCount}}' "$DB")"
  echo "NOTE: changing Web.config may recycle the ASP.NET workers automatically."
  echo "Next: run '$0 test' for one controlled restart + route probe."
}

status(){
  preflight_common
  echo "============================================================"
  echo " BRIMSTONE v0.005 — HANDLER MAP STATUS"
  echo "============================================================"
  echo "Connector DLL   : $(live_dll_hash)"
  echo "MySQL restarts  : $(docker inspect -f '{{.RestartCount}}' "$DB")"
  echo "path mappings   : $(map_path_count)"
  echo "exact mappings  : $(map_exact_count)"
  echo "MySQL safe calls: $(mysql_safe_count)"
  echo
  docker exec "$C" sh -lc "grep -n -B 2 -A 2 -F 'path=\"$MAP_PATH\"' '$WEB' || true"
}

rollback(){
  preflight_common
  local backup uid gid mode
  backup="$(find "$BACKUP_ROOT" -maxdepth 1 -type d -name 'brimstone-handler-map-*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1{$1=""; sub(/^ /,""); print; exit}')"
  [[ -n "$backup" && -s "$backup/Web.config" ]] || fail "no handler-map backup found"
  (cd "$backup" && sha256sum -c SHA256SUMS >/dev/null) || fail "backup checksum failed"
  validate_xml "$backup/Web.config"

  read -r uid gid mode < <(docker exec "$C" stat -c '%u %g %a' "$WEB")
  docker cp "$backup/Web.config" "$C:/tmp/brimstone-Web.config.rollback" >/dev/null
  docker exec "$C" install -o "$uid" -g "$gid" -m "$mode" /tmp/brimstone-Web.config.rollback "$WEB"
  docker exec "$C" rm -f /tmp/brimstone-Web.config.rollback

  echo "ROLLBACK COMPLETE from $backup"
  echo "path mappings  : $(map_path_count)"
  echo "exact mappings : $(map_exact_count)"
  echo "No explicit restart performed."
}

wait_ready(){
  local deadline=$((SECONDS + 240)) elapsed body http
  while (( SECONDS < deadline )); do
    elapsed=$((240 - (deadline - SECONDS)))
    body="$(docker exec "$C" sh -lc 'curl -sS -m 5 http://127.0.0.1/api/2.0/warmup/progress.json 2>/dev/null || true')"
    if printf '%s' "$body" | grep -Eq '"Completed"[[:space:]]*:[[:space:]]*true|\\"Completed\\"[[:space:]]*:[[:space:]]*true'; then
      echo "PASS: ONLYOFFICE warmup completed after ${elapsed}s"
      return 0
    fi
    if (( elapsed > 0 && elapsed % 30 == 0 )); then
      http="$(docker exec "$C" sh -lc 'curl -sS -m 5 -o /dev/null -w "%{http_code}" http://127.0.0.1/api/2.0/capabilities.json 2>/dev/null || true')"
      echo "INFO: ${elapsed}s — still warming (capabilities HTTP ${http:-000})"
    fi
    sleep 3
  done
  return 1
}

test_restart(){
  preflight_common
  [[ "$(map_path_count)" == "1" ]] || fail "handler mapping not installed"
  [[ "$(map_exact_count)" == "1" ]] || fail "exact handler mapping not installed"
  [[ "$(mysql_safe_count)" == "2" ]] || fail "external-MySQL protection missing"

  local before started after code body headers
  before="$(docker inspect -f '{{.RestartCount}}' "$DB")"
  started="$(docker inspect -f '{{.State.StartedAt}}' "$DB")"

  echo "============================================================"
  echo " CONTROLLED HANDLER-MAP RESTART TEST"
  echo "============================================================"
  echo "MySQL restart count before: $before"
  echo "MySQL StartedAt before     : $started"
  echo "Restarting CommunityServer only..."
  docker restart "$C" >/dev/null

  if ! wait_ready; then
    echo "FAIL: CommunityServer did not complete warmup"
    echo "Restoring previous Web.config..."
    rollback || true
    docker restart "$C" >/dev/null || true
    return 1
  fi

  after="$(docker inspect -f '{{.RestartCount}}' "$DB")"
  if [[ "$after" != "$before" ]]; then
    echo "FAIL: MySQL restart count changed from $before to $after"
    rollback || true
    return 1
  fi
  [[ "$(docker inspect -f '{{.State.StartedAt}}' "$DB")" == "$started" ]] || {
    echo "FAIL: MySQL StartedAt changed"
    rollback || true
    return 1
  }

  headers="$(mktemp)"
  body="$(mktemp)"
  trap 'rm -f "$headers" "$body"' RETURN
  code="$(docker exec "$C" sh -lc "curl -sS -D /tmp/brimstone-handler-map.headers -o /tmp/brimstone-handler-map.body -w '%{http_code}' -X POST --data-urlencode 'action=list-buckets' --data-urlencode 'source=manual' --data-urlencode 'accessKey=x' --data-urlencode 'secretKey=y' http://127.0.0.1/Products/Files/HttpHandlers/brimstone-megas4.ashx || true")"
  docker cp "$C:/tmp/brimstone-handler-map.headers" "$headers" >/dev/null 2>&1 || true
  docker cp "$C:/tmp/brimstone-handler-map.body" "$body" >/dev/null 2>&1 || true
  docker exec "$C" rm -f /tmp/brimstone-handler-map.headers /tmp/brimstone-handler-map.body >/dev/null 2>&1 || true

  echo "Route probe HTTP: ${code:-unknown}"
  echo "--- headers ---"
  sed -n '1,25p' "$headers" 2>/dev/null || true
  echo "--- body ---"
  sed -n '1,25p' "$body" 2>/dev/null || true

  if grep -Fq '<%@ WebHandler' "$body" 2>/dev/null || grep -Fq 'marker file generated by the precompilation tool' "$body" 2>/dev/null; then
    echo "FAIL: request still resolved to physical .ashx content instead of compiled handler"
    rollback || true
    return 1
  fi

  if grep -Fq 'BRIMSTONE MEGA S4 handler error:' "$body" 2>/dev/null || grep -Fq 'Authentication required.' "$body" 2>/dev/null; then
    echo "PASS: Brimstone compiled handler executed (credential-free/auth diagnostic returned)"
  elif [[ "$code" == "500" || -z "$code" || "$code" == "000" ]]; then
    echo "FAIL: generic/non-Brimstone handler failure HTTP ${code:-unknown}"
    rollback || true
    return 1
  else
    echo "PASS: route no longer resolves to physical .ashx source/marker"
  fi

  echo "PASS: MySQL restart count remains $before"
  echo "PASS: MySQL StartedAt unchanged"
  echo "PASS: Connector DLL remains $(live_dll_hash)"
  echo "NOTE: anonymous local probe may return auth/redirect; final typed-credential acceptance is through the authenticated Files UI."
}

case "${1:-status}" in
  preflight) preflight ;;
  install) install ;;
  status) status ;;
  test) test_restart ;;
  rollback) rollback ;;
  *) echo "Usage: $0 {preflight|install|status|test|rollback}" >&2; exit 2 ;;
esac
