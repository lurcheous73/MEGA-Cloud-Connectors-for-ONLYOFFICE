#!/usr/bin/env bash
set -Eeuo pipefail

# BRIMSTONE CUSTOM CODE — fail-closed cleanup for a single failed MEGA S4 provider row.
# This helper never deletes mappings/security/tag rows. If any MEGA mapping exists it stops
# and requires manual review, because that means the provider progressed further than a
# simple failed connection attempt.

COMMUNITY_CONTAINER="${COMMUNITY_CONTAINER:-onlyoffice-community-server}"
DB_CONTAINER="${DB_CONTAINER:-onlyoffice-mysql-server}"
DATABASE="${DATABASE:-onlyoffice}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/mega-cloud-connectors-for-onlyoffice}"
EXPECTED_LIVE_DLL_HASH="${EXPECTED_LIVE_DLL_HASH:-3540c74cde53997e680846bd05c86eedbb678d544f16f56de5fbe916393037f2}"

fail() { echo "FAIL: $*" >&2; exit 1; }

mysql_query() {
  local sql="$1"
  docker exec -e SQL="$sql" "$DB_CONTAINER" sh -lc '
    mysql --batch --raw --skip-column-names \
      -uroot -p"$MYSQL_ROOT_PASSWORD" "$0" -e "$SQL"
  ' "$DATABASE" 2>/dev/null
}

echo "============================================================"
echo " BRIMSTONE MEGA S4 — ZOMBIE PROVIDER CLEANUP"
echo "============================================================"

docker inspect "$COMMUNITY_CONTAINER" >/dev/null 2>&1 || fail "CommunityServer container not found"
docker inspect "$DB_CONTAINER" >/dev/null 2>&1 || fail "MySQL container not found"

[[ "$(docker inspect -f '{{.State.Running}}' "$COMMUNITY_CONTAINER")" == "true" ]] || fail "CommunityServer is not running"
[[ "$(docker inspect -f '{{.State.Running}}' "$DB_CONTAINER")" == "true" ]] || fail "MySQL is not running"

LIVE_HASH="$(docker exec "$COMMUNITY_CONTAINER" sha256sum /var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll | awk '{print $1}')"
[[ "$LIVE_HASH" == "$EXPECTED_LIVE_DLL_HASH" ]] || fail "unexpected live Thirdparty DLL: $LIVE_HASH"
echo "PASS: expected provider-contract live DLL"

COUNT="$(mysql_query "SELECT COUNT(*) FROM files_thirdparty_account WHERE LOWER(provider)='megas4';")"
[[ "$COUNT" == "1" ]] || fail "expected exactly one MegaS4 provider row, found $COUNT"

ROW="$(mysql_query "SELECT id,tenant_id,provider,customer_title,user_name,user_id,folder_type,create_on,url FROM files_thirdparty_account WHERE LOWER(provider)='megas4';")"
[[ -n "$ROW" ]] || fail "MegaS4 row disappeared during inspection"

ID="$(printf '%s\n' "$ROW" | awk -F '\t' '{print $1}')"
TENANT="$(printf '%s\n' "$ROW" | awk -F '\t' '{print $2}')"
[[ "$ID" =~ ^[0-9]+$ ]] || fail "invalid provider id: $ID"
[[ "$TENANT" =~ ^[0-9]+$ ]] || fail "invalid tenant id: $TENANT"

echo
echo "=== FAILED PROVIDER ROW ==="
printf '%s\n' "$ROW"

MAP_COUNT="$(mysql_query "SELECT COUNT(*) FROM files_thirdparty_id_mapping WHERE tenant_id=$TENANT AND (id LIKE 'sbox-megas4-$ID%' OR id LIKE 'megas4-$ID%' OR hash_id LIKE 'megas4-$ID%');")"
[[ "$MAP_COUNT" == "0" ]] || fail "provider $ID has $MAP_COUNT MEGA mapping row(s); refusing simple cleanup"
echo "PASS: provider $ID has no MEGA mapping rows"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BACKUP_ROOT/brimstone-megas4-zombie-${ID}-${STAMP}"
mkdir -p "$BACKUP"
chmod 700 "$BACKUP"

# Back up exactly the row that will be removed.
docker exec -e ID="$ID" -e TENANT="$TENANT" "$DB_CONTAINER" sh -lc '
  mysqldump \
    -uroot -p"$MYSQL_ROOT_PASSWORD" \
    --no-create-info \
    --skip-triggers \
    --single-transaction \
    onlyoffice files_thirdparty_account \
    --where="tenant_id=$TENANT AND id=$ID AND provider=\"MegaS4\""
' > "$BACKUP/files_thirdparty_account.sql"

[[ -s "$BACKUP/files_thirdparty_account.sql" ]] || fail "backup dump is empty"
printf '%s\n' "$ROW" > "$BACKUP/provider-row.tsv"
(
  cd "$BACKUP"
  sha256sum files_thirdparty_account.sql provider-row.tsv > SHA256SUMS
  sha256sum -c SHA256SUMS
)
echo "PASS: exact provider row backed up to $BACKUP"

echo
echo "=== STOP COMMUNITYSERVER ==="
docker stop "$COMMUNITY_CONTAINER" >/dev/null
[[ "$(docker inspect -f '{{.State.Running}}' "$COMMUNITY_CONTAINER")" == "false" ]] || fail "CommunityServer failed to stop"

echo "=== DELETE EXACT FAILED PROVIDER ROW ==="
mysql_query "DELETE FROM files_thirdparty_account WHERE tenant_id=$TENANT AND id=$ID AND LOWER(provider)='megas4';"

LEFT="$(mysql_query "SELECT COUNT(*) FROM files_thirdparty_account WHERE LOWER(provider)='megas4';")"
[[ "$LEFT" == "0" ]] || fail "MegaS4 provider rows remain: $LEFT"
echo "PASS: provider row removed"

echo "=== START COMMUNITYSERVER ==="
docker start "$COMMUNITY_CONTAINER" >/dev/null
sleep 10
[[ "$(docker inspect -f '{{.State.Running}}' "$COMMUNITY_CONTAINER")" == "true" ]] || fail "CommunityServer failed to restart"

POST_HASH="$(docker exec "$COMMUNITY_CONTAINER" sha256sum /var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll | awk '{print $1}')"
[[ "$POST_HASH" == "$EXPECTED_LIVE_DLL_HASH" ]] || fail "live DLL changed unexpectedly: $POST_HASH"

OLD_MAPS="$(mysql_query "SELECT COUNT(*) FROM files_thirdparty_id_mapping WHERE id LIKE 'megas4-%' OR hash_id LIKE 'megas4-%';")"
[[ "$OLD_MAPS" == "0" ]] || fail "old-prefix MEGA mappings exist after cleanup: $OLD_MAPS"

echo
echo "============================================================"
echo " PASS — BRIMSTONE MEGA S4 ZOMBIE REMOVED"
echo " Provider ID: $ID"
echo " Backup     : $BACKUP"
echo " Mega rows  : 0"
echo " Old maps   : 0"
echo " Live DLL   : $POST_HASH"
echo "============================================================"
