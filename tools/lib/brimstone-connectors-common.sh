#!/usr/bin/env bash
# BRIMSTONE CUSTOM CODE — shared production installer/runtime helpers.
# shellcheck shell=bash

BRIMSTONE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BRIMSTONE_CONTAINER="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
BRIMSTONE_DB_CONTAINER="${MYSQL_CONTAINER:-onlyoffice-mysql-server}"
BRIMSTONE_IMAGE="onlyoffice/communityserver:12.8.0.1971"
BRIMSTONE_BACKUP_ROOT="${BRIMSTONE_BACKUP_ROOT:-/var/backups/mega-cloud-connectors-for-onlyoffice}"
BRIMSTONE_STATE_ROOT="${BRIMSTONE_STATE_ROOT:-/var/lib/brimstone-connectors}"

BRIMSTONE_LIVE_DLL="/var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll"
BRIMSTONE_RUN_SCRIPT="/app/run-community-server.sh"
BRIMSTONE_HANDLER="/var/www/onlyoffice/WebStudio/Products/Files/HttpHandlers/brimstone-megas4.ashx"
BRIMSTONE_COMPILED="/var/www/onlyoffice/WebStudio/bin/brimstone-megas4.ashx.brimstone.compiled"
BRIMSTONE_WEB_CONFIG="/var/www/onlyoffice/WebStudio/Web.config"
BRIMSTONE_PRECOMPILED="/var/www/onlyoffice/WebStudio/PrecompiledApp.config"
BRIMSTONE_HANDLER_VPATH="/Products/Files/HttpHandlers/brimstone-megas4.ashx"
BRIMSTONE_HANDLER_MAP_PATH="Products/Files/HttpHandlers/brimstone-megas4.ashx"
BRIMSTONE_STOCK_MARKER="/var/www/onlyoffice/WebStudio/Products/Files/HttpHandlers/thirdpartyapphandler.ashx"
BRIMSTONE_STOCK_MARKER_SHA="24fce7c547069682c963ad5bdddc3b597df0f6dc02b663e7f243a85f4ba23f9a"

BRIMSTONE_UI_ASSET="$BRIMSTONE_ROOT/src/mega-s4/communityserver-12.8/ui/mega-s4-thirdparty-accepted.js"
BRIMSTONE_UI_SHA="ee90cfbd7e6ed94008e555e501bde917b39677c49da8a47924112c614888f967"
BRIMSTONE_HANDLER_MARKER_ASSET="$BRIMSTONE_ROOT/src/mega-s4/communityserver-12.8/ui/brimstone-megas4.marker"
BRIMSTONE_HANDLER_COMPILED_ASSET="$BRIMSTONE_ROOT/src/mega-s4/communityserver-12.8/ui/brimstone-megas4.ashx.brimstone.compiled"

BRIMSTONE_UI_PATHS=(
  "/var/www/onlyoffice/WebStudio/Products/Files/Controls/ThirdParty/thirdparty.js"
  "/var/www/onlyoffice/Data/bundle/files/javascript/files-6zQSAGbsjVfnA1EyaHmOMQ2.js"
  "/var/www/onlyoffice/WebStudio/App_Data/static/bundle/files/javascript/files-6zQSAGbsjVfnA1EyaHmOMQ2.js"
)

brimstone_fail(){ echo "BRIMSTONE FAIL: $*" >&2; return 1; }
brimstone_note(){ echo "BRIMSTONE: $*"; }
brimstone_sha(){ sha256sum "$1" | awk '{print $1}'; }
brimstone_live_sha(){ docker exec "$BRIMSTONE_CONTAINER" sha256sum "$1" | awk '{print $1}'; }

brimstone_require_host(){
  local x
  for x in docker git python3 sha256sum gzip awk grep sed; do
    command -v "$x" >/dev/null 2>&1 || brimstone_fail "required host command missing: $x" || return 1
  done
}

brimstone_repo_preflight(){
  [[ -d "$BRIMSTONE_ROOT/.git" || -f "$BRIMSTONE_ROOT/.git" ]] || brimstone_fail "connector repository missing: $BRIMSTONE_ROOT" || return 1
  [[ -z "$(git -C "$BRIMSTONE_ROOT" status --porcelain --untracked-files=normal)" ]] || {
    git -C "$BRIMSTONE_ROOT" status --short >&2
    brimstone_fail "connector repository is dirty"
    return 1
  }
  [[ -s "$BRIMSTONE_UI_ASSET" ]] || brimstone_fail "accepted S4 UI asset missing" || return 1
  [[ "$(brimstone_sha "$BRIMSTONE_UI_ASSET")" == "$BRIMSTONE_UI_SHA" ]] || brimstone_fail "accepted S4 UI asset hash mismatch" || return 1
}

brimstone_platform_preflight(){
  brimstone_require_host || return 1
  docker inspect "$BRIMSTONE_CONTAINER" >/dev/null 2>&1 || brimstone_fail "CommunityServer container missing: $BRIMSTONE_CONTAINER" || return 1
  docker inspect "$BRIMSTONE_DB_CONTAINER" >/dev/null 2>&1 || brimstone_fail "MySQL container missing: $BRIMSTONE_DB_CONTAINER" || return 1
  [[ "$(docker inspect -f '{{.State.Running}}' "$BRIMSTONE_CONTAINER")" == "true" ]] || brimstone_fail "CommunityServer is not running" || return 1
  [[ "$(docker inspect -f '{{.State.Running}}' "$BRIMSTONE_DB_CONTAINER")" == "true" ]] || brimstone_fail "MySQL is not running" || return 1
  [[ "$(docker inspect -f '{{.Config.Image}}' "$BRIMSTONE_CONTAINER")" == "$BRIMSTONE_IMAGE" ]] || brimstone_fail "unsupported CommunityServer image" || return 1
}

brimstone_mysql_plain_count(){
  docker exec "$BRIMSTONE_CONTAINER" sh -lc "awk '/^[[:space:]]*mysqladmin shutdown[[:space:]]*\$/ {n++} END {print n+0}' '$BRIMSTONE_RUN_SCRIPT'"
}

brimstone_mysql_safe_count(){
  docker exec "$BRIMSTONE_CONTAINER" sh -lc "awk '/^[[:space:]]*mysqladmin --no-defaults --protocol=socket --socket=\\/var\\/run\\/mysqld\\/mysqld.sock shutdown \\|\\| true[[:space:]]*\$/ {n++} END {print n+0}' '$BRIMSTONE_RUN_SCRIPT'"
}

brimstone_mysql_host(){
  docker exec "$BRIMSTONE_CONTAINER" sh -lc "awk -F= 'tolower(\$1)==\"host\"{gsub(/[[:space:]]/,\"\",\$2); print \$2; exit}' /etc/mysql/conf.d/root.cnf 2>/dev/null || true"
}

brimstone_mysql_snapshot(){
  printf '%s|%s\n' \
    "$(docker inspect -f '{{.RestartCount}}' "$BRIMSTONE_DB_CONTAINER")" \
    "$(docker inspect -f '{{.State.StartedAt}}' "$BRIMSTONE_DB_CONTAINER")"
}

brimstone_mysql_assert_snapshot(){
  local before="$1" now
  now="$(brimstone_mysql_snapshot)"
  [[ "$now" == "$before" ]] || brimstone_fail "external MySQL state changed: before=$before after=$now" || return 1
}

brimstone_install_mysql_protection(){
  local backup_dir="$1" p s tmp patched
  p="$(brimstone_mysql_plain_count)"
  s="$(brimstone_mysql_safe_count)"
  [[ "$(brimstone_mysql_host)" == "onlyoffice-mysql-server" ]] || brimstone_fail "root.cnf is not targeting onlyoffice-mysql-server" || return 1

  if [[ "$p" == "0" && "$s" == "2" ]]; then
    echo "PASS: external-MySQL restart protection already installed"
    return 0
  fi
  [[ "$p" == "2" && "$s" == "0" ]] || brimstone_fail "unexpected CommunityServer mysqladmin shutdown state: plain=$p safe=$s" || return 1

  mkdir -p "$backup_dir"
  docker cp "$BRIMSTONE_CONTAINER:$BRIMSTONE_RUN_SCRIPT" "$backup_dir/run-community-server.sh.pre-mysql-protection" >/dev/null
  sha256sum "$backup_dir/run-community-server.sh.pre-mysql-protection" > "$backup_dir/run-community-server.sh.pre-mysql-protection.sha256"

  tmp="$(mktemp)"; patched="$(mktemp)"
  docker cp "$BRIMSTONE_CONTAINER:$BRIMSTONE_RUN_SCRIPT" "$tmp" >/dev/null
  awk -v safe='mysqladmin --no-defaults --protocol=socket --socket=/var/run/mysqld/mysqld.sock shutdown || true' '
    /^[[:space:]]*mysqladmin shutdown[[:space:]]*$/ {
      match($0, /^[[:space:]]*/); print substr($0,RSTART,RLENGTH) safe; n++; next
    }
    { print }
    END { if (n != 2) exit 42 }
  ' "$tmp" > "$patched" || { rm -f "$tmp" "$patched"; brimstone_fail "could not patch exactly two mysqladmin shutdown lines"; return 1; }
  bash -n "$patched" || { rm -f "$tmp" "$patched"; brimstone_fail "patched CommunityServer run script is invalid"; return 1; }
  docker cp "$patched" "$BRIMSTONE_CONTAINER:/tmp/brimstone-run-community-server.sh" >/dev/null
  docker exec "$BRIMSTONE_CONTAINER" install -o 0 -g 0 -m 755 /tmp/brimstone-run-community-server.sh "$BRIMSTONE_RUN_SCRIPT"
  docker exec "$BRIMSTONE_CONTAINER" rm -f /tmp/brimstone-run-community-server.sh
  rm -f "$tmp" "$patched"
  [[ "$(brimstone_mysql_plain_count)" == "0" && "$(brimstone_mysql_safe_count)" == "2" ]] || brimstone_fail "external-MySQL protection did not validate after install" || return 1
  echo "PASS: external-MySQL restart protection installed"
}

brimstone_wait_ready(){
  local deadline=$((SECONDS + 240)) body elapsed
  while (( SECONDS < deadline )); do
    body="$(docker exec "$BRIMSTONE_CONTAINER" sh -lc 'curl -sS -m 5 http://127.0.0.1/api/2.0/warmup/progress.json 2>/dev/null || true')"
    if printf '%s' "$body" | grep -Eq '"Completed"[[:space:]]*:[[:space:]]*true|\\"Completed\\"[[:space:]]*:[[:space:]]*true'; then
      echo "PASS: CommunityServer warmup complete"
      return 0
    fi
    elapsed=$((240 - (deadline - SECONDS)))
    if (( elapsed > 0 && elapsed % 30 == 0 )); then echo "INFO: ${elapsed}s — CommunityServer still warming"; fi
    sleep 3
  done
  brimstone_fail "CommunityServer did not complete warmup"
}

brimstone_handler_ref_count(){
  docker exec "$BRIMSTONE_CONTAINER" sh -lc "find /var/www/onlyoffice/WebStudio/bin -maxdepth 1 -type f -name '*.compiled' -exec grep -lF '$BRIMSTONE_HANDLER_VPATH' {} + 2>/dev/null | wc -l" | tr -d '[:space:]'
}

brimstone_web_map_count(){
  docker exec "$BRIMSTONE_CONTAINER" sh -lc "grep -Fc 'path=\"$BRIMSTONE_HANDLER_MAP_PATH\"' '$BRIMSTONE_WEB_CONFIG' || true" | tr -d '[:space:]'
}

brimstone_validate_ui_asset(){
  python3 - "$BRIMSTONE_UI_ASSET" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
need=[
 'MEGA S4 LIVE EXTENSION v1',
 'MEGA S4 LIVE EXTENSION v2',
 'MEGA S4 LIVE EXTENSION v3',
 'BRIMSTONE HOTFIX — legacy v3 MutationObserver disabled',
 'BRIMSTONE MEGA S4 LIVE EXTENSION v4.1',
 'observer = new MutationObserver(queueNormalise)'
]
for x in need:
    if x not in s: raise SystemExit('missing accepted UI marker: '+x)
if 'observer = new MutationObserver(function () {\n                normaliseMegaS4Form();' in s:
    raise SystemExit('legacy v3 MutationObserver remains active')
print('PASS: accepted Safari-safe S4 UI asset validates')
PY
}

brimstone_live_ui_tail_hash(){
  local path="$1" tmp out
  tmp="$(mktemp)"; out="$(mktemp)"
  docker cp "$BRIMSTONE_CONTAINER:$path" "$tmp" >/dev/null 2>&1 || { rm -f "$tmp" "$out"; return 1; }
  python3 - "$tmp" "$out" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(errors='strict')
m='/* MEGA S4 LIVE EXTENSION v1'
i=s.find(m)
if i < 0: raise SystemExit(2)
Path(sys.argv[2]).write_text(s[i:])
PY
  local rc=$?
  if [[ $rc -ne 0 ]]; then rm -f "$tmp" "$out"; return "$rc"; fi
  sha256sum "$out" | awk '{print $1}'
  rm -f "$tmp" "$out"
}

brimstone_validate_live_dll(){
  docker exec "$BRIMSTONE_CONTAINER" bash -lc '
set -e
DLL=/var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll
T=$(mktemp); S=$(mktemp); trap "rm -f \"$T\" \"$S\"" EXIT
monodis --typedef "$DLL" >"$T"
monodis --userstrings "$DLL" >"$S"
grep -Fq "ASC.Files.Thirdparty.MegaS4.MegaS4DaoSelector" "$T"
grep -Fq "ASC.Files.Thirdparty.BrimstoneMegaCloud.BrimstoneMegaCloudDaoSelector" "$T"
grep -Fq "sboxmega-" "$S"
! grep -Fq "sbox-megas4-" "$S"
'
  echo "PASS: live DLL contains both providers and browser-compatible sboxmega namespace"
}
