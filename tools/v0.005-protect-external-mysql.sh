#!/usr/bin/env bash
set -Eeuo pipefail

# BRIMSTONE CUSTOM CODE — protect external MySQL from CommunityServer startup.
# ONLYOFFICE CommunityServer's run script contains two plain `mysqladmin shutdown`
# calls. With /etc/mysql/conf.d/root.cnf pointing at the external MySQL container,
# those calls shut down the external DB. This tool replaces only the exact two
# plain calls with a local-socket-only mysqladmin command.

REPO="${REPO:-/opt/mega-cloud-connectors-for-onlyoffice}"
C="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
DB="${MYSQL_CONTAINER:-onlyoffice-mysql-server}"
TARGET="/app/run-community-server.sh"
EXPECTED_IMAGE="onlyoffice/communityserver:12.8.0.1971"
EXPECTED_DLL="62bdff5b75ab9db37108a6f772a92240805879f0cf400bb8c2813d2aa68b679f"
LIVE_DLL="/var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll"
BACKUP_ROOT="/var/backups/mega-cloud-connectors-for-onlyoffice"
SAFE_CMD='mysqladmin --no-defaults --protocol=socket --socket=/var/run/mysqld/mysqld.sock shutdown || true'

fail(){ echo "FAIL: $*" >&2; exit 1; }
branch(){ git -C "$REPO" rev-parse --abbrev-ref HEAD; }
worktree_clean(){ [[ -z "$(git -C "$REPO" status --porcelain)" ]]; }
live_dll_hash(){ docker exec "$C" sha256sum "$LIVE_DLL" | awk '{print $1}'; }
plain_count(){
  docker exec "$C" sh -lc "awk '/^[[:space:]]*mysqladmin shutdown[[:space:]]*\$/ {n++} END {print n+0}' '$TARGET'"
}
safe_count(){
  docker exec "$C" sh -lc "awk '/^[[:space:]]*mysqladmin --no-defaults --protocol=socket --socket=\\/var\\/run\\/mysqld\\/mysqld.sock shutdown \\|\\| true[[:space:]]*\$/ {n++} END {print n+0}' '$TARGET'"
}

preflight_common(){
  [[ -d "$REPO/.git" ]] || fail "repo missing: $REPO"
  [[ "$(branch)" == "v0.005-typed-creds" ]] || fail "checkout v0.005-typed-creds first"
  worktree_clean || fail "repo worktree is not clean"
  docker inspect "$C" >/dev/null 2>&1 || fail "CommunityServer container missing"
  docker inspect "$DB" >/dev/null 2>&1 || fail "MySQL container missing"
  [[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer is not running"
  [[ "$(docker inspect -f '{{.State.Running}}' "$DB")" == "true" ]] || fail "MySQL is not running"
  [[ "$(docker inspect -f '{{.Config.Image}}' "$C")" == "$EXPECTED_IMAGE" ]] || fail "unexpected CommunityServer image"
  [[ "$(live_dll_hash)" == "$EXPECTED_DLL" ]] || fail "live connector DLL is not the locked v0.004/v0.005 baseline"
  docker exec "$C" test -s "$TARGET" || fail "missing $TARGET"
}

preflight(){
  preflight_common
  local p s host
  p="$(plain_count)"
  s="$(safe_count)"
  host="$(docker exec "$C" sh -lc "awk -F= 'tolower(\$1)==\"host\"{gsub(/[[:space:]]/,\"\",\$2); print \$2; exit}' /etc/mysql/conf.d/root.cnf 2>/dev/null || true")"

  echo "============================================================"
  echo " BRIMSTONE v0.005 — EXTERNAL MYSQL PROTECTION PRE-FLIGHT"
  echo "============================================================"
  echo "Community image : $EXPECTED_IMAGE"
  echo "Connector DLL   : $(live_dll_hash)"
  echo "root.cnf host   : ${host:-unknown}"
  echo "plain shutdowns : $p"
  echo "safe shutdowns  : $s"

  [[ "$host" == "onlyoffice-mysql-server" ]] || fail "root.cnf is not targeting the expected external MySQL container"
  if [[ "$p" == "2" && "$s" == "0" ]]; then
    echo "PASS: exact vulnerable baseline detected"
    return 0
  fi
  if [[ "$p" == "0" && "$s" == "2" ]]; then
    echo "PASS: protection is already installed"
    return 0
  fi
  fail "unexpected run script state; refusing to patch"
}

install(){
  preflight_common
  [[ "$(plain_count)" == "2" ]] || fail "expected exactly two plain mysqladmin shutdown lines"
  [[ "$(safe_count)" == "0" ]] || fail "safe command already present unexpectedly"

  local stamp backup tmp patched patched_safe_count
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="$BACKUP_ROOT/brimstone-communityserver-mysql-protect-$stamp"
  mkdir -p "$backup"
  docker cp "$C:$TARGET" "$backup/run-community-server.sh" >/dev/null
  sha256sum "$backup/run-community-server.sh" > "$backup/run-community-server.sh.sha256"

  tmp="$(mktemp)"
  patched="$(mktemp)"
  trap 'rm -f "$tmp" "$patched"' RETURN
  docker cp "$C:$TARGET" "$tmp" >/dev/null

  awk -v safe="$SAFE_CMD" '
    /^[[:space:]]*mysqladmin shutdown[[:space:]]*$/ {
      match($0, /^[[:space:]]*/)
      indent=substr($0, RSTART, RLENGTH)
      print indent safe
      n++
      next
    }
    { print }
    END { if (n != 2) exit 42 }
  ' "$tmp" > "$patched" || fail "failed to produce exact two-line patch"

  bash -n "$patched" || fail "patched run script fails bash syntax validation"
  [[ "$(awk '/^[[:space:]]*mysqladmin shutdown[[:space:]]*$/ {n++} END {print n+0}' "$patched")" == "0" ]] || fail "patched temp still contains plain shutdown"
  patched_safe_count="$(awk '/^[[:space:]]*mysqladmin --no-defaults --protocol=socket --socket=\/var\/run\/mysqld\/mysqld.sock shutdown \|\| true[[:space:]]*$/ {n++} END {print n+0}' "$patched")"
  [[ "$patched_safe_count" == "2" ]] || fail "patched temp does not contain exactly two safe commands"

  docker cp "$patched" "$C:$TARGET" >/dev/null
  docker exec "$C" chmod 755 "$TARGET"

  [[ "$(plain_count)" == "0" ]] || fail "live script still contains plain shutdown"
  [[ "$(safe_count)" == "2" ]] || fail "live script does not contain exactly two safe commands"

  echo "============================================================"
  echo " INSTALLED — NO RESTART PERFORMED"
  echo "============================================================"
  echo "Backup: $backup"
  echo "Live run script now has two local-socket-only shutdown calls."
  echo "Connector DLL remains: $(live_dll_hash)"
  echo "Next: run '$0 test' for one controlled CommunityServer restart."
}

status(){
  preflight_common
  echo "============================================================"
  echo " BRIMSTONE v0.005 — MYSQL PROTECTION STATUS"
  echo "============================================================"
  echo "Connector DLL   : $(live_dll_hash)"
  echo "MySQL restarts  : $(docker inspect -f '{{.RestartCount}}' "$DB")"
  echo "plain shutdowns : $(plain_count)"
  echo "safe shutdowns  : $(safe_count)"
  echo
  docker exec "$C" sh -lc "grep -n -B 2 -A 2 -E 'mysqladmin .*shutdown' '$TARGET' || true"
}

rollback(){
  preflight_common
  local backup
  backup="$(find "$BACKUP_ROOT" -maxdepth 1 -type d -name 'brimstone-communityserver-mysql-protect-*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1{$1=""; sub(/^ /,""); print; exit}')"
  [[ -n "$backup" && -s "$backup/run-community-server.sh" ]] || fail "no protection backup found"
  sha256sum -c "$backup/run-community-server.sh.sha256" >/dev/null || fail "backup checksum failed"
  bash -n "$backup/run-community-server.sh" || fail "backup script syntax invalid"
  docker cp "$backup/run-community-server.sh" "$C:$TARGET" >/dev/null
  docker exec "$C" chmod 755 "$TARGET"
  echo "ROLLBACK COMPLETE from $backup"
  echo "plain shutdowns : $(plain_count)"
  echo "safe shutdowns  : $(safe_count)"
  echo "No restart performed."
}

test_restart(){
  preflight_common
  [[ "$(plain_count)" == "0" ]] || fail "protection not installed: plain shutdown remains"
  [[ "$(safe_count)" == "2" ]] || fail "protection not installed: expected two safe commands"

  local before after started deadline elapsed
  before="$(docker inspect -f '{{.RestartCount}}' "$DB")"
  started="$(docker inspect -f '{{.State.StartedAt}}' "$DB")"

  echo "============================================================"
  echo " CONTROLLED COMMUNITYSERVER RESTART TEST"
  echo "============================================================"
  echo "MySQL restart count before: $before"
  echo "MySQL StartedAt before     : $started"
  echo "Restarting CommunityServer only..."
  docker restart "$C" >/dev/null

  deadline=$((SECONDS + 180))
  elapsed=0
  while (( SECONDS < deadline )); do
    after="$(docker inspect -f '{{.RestartCount}}' "$DB" 2>/dev/null || echo unavailable)"
    if [[ "$after" != "$before" ]]; then
      echo "FAIL: MySQL restart count changed from $before to $after"
      echo "Restoring original run script immediately (no further restart)..."
      rollback || true
      return 1
    fi

    elapsed=$((elapsed + 5))
    if (( elapsed % 30 == 0 )); then
      echo "INFO: ${elapsed}s — MySQL restart count still $before"
    fi

    if [[ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null || true)" == "true" ]] && (( elapsed >= 120 )); then
      echo "PASS: MySQL restart count remained $before for ${elapsed} seconds"
      echo "PASS: MySQL StartedAt unchanged: $(docker inspect -f '{{.State.StartedAt}}' "$DB")"
      echo "CommunityServer running: $(docker inspect -f '{{.State.Running}}' "$C")"
      echo "Connector DLL: $(live_dll_hash)"
      return 0
    fi
    sleep 5
  done

  fail "CommunityServer did not remain running long enough to complete restart test"
}

case "${1:-status}" in
  preflight) preflight ;;
  install) install ;;
  status) status ;;
  rollback) rollback ;;
  test) test_restart ;;
  *) echo "Usage: $0 {preflight|install|status|test|rollback}" >&2; exit 2 ;;
esac
