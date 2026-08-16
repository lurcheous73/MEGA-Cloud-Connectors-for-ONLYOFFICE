#!/usr/bin/env bash
set -Eeuo pipefail

# BRIMSTONE CUSTOM CODE — canonical MEGA S4 v4.1 deployment path.
# Fresh installs deploy the exact-hash v4 backend/handler and immediately replace
# the v4 UI tail with the idempotent v4.1 overlay before the deployment is handed
# to a user. Existing v4 installs may use mode=upgrade directly.
MODE="${1:-status}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/deploy-brimstone-mega-s4-v4.sh"
LOOPFIX="$SCRIPT_DIR/upgrade-brimstone-mega-s4-v4.1-ui-loopfix.sh"
C="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
DB="${MYSQL_CONTAINER:-onlyoffice-mysql-server}"
DLL="/var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll"
EXPECTED_DLL="a5d6698434ef9a18909aa6a2b42657472d832396a918ae648bee2c63255133d2"
NEW_MARKER="BRIMSTONE MEGA S4 LIVE EXTENSION v4.1"

fail(){ echo "FAIL: $*" >&2; exit 1; }

status_v41(){
  docker inspect "$C" >/dev/null 2>&1 || fail "CommunityServer missing"
  echo "Live DLL : $(docker exec "$C" sha256sum "$DLL" | awk '{print $1}')"
  mapfile -t JS < <(docker exec "$C" sh -lc "find /var/www/onlyoffice -path '*/Products/Files/Controls/ThirdParty/thirdparty.js' -type f -print; find /var/www/onlyoffice -path '*/App_Data/static/bundle/files/javascript/files-*.js' -type f -print; find /var/www/onlyoffice/Data/bundle/files/javascript -maxdepth 1 -type f -name 'files-*.js' -print" | tr -d '\r')
  local marked=0 f
  for f in "${JS[@]}"; do
    if [[ "$(docker exec "$C" grep -aFc "$NEW_MARKER" "$f")" -eq 1 ]]; then marked=$((marked+1)); fi
  done
  echo "UI v4.1 : $marked/${#JS[@]} marked"
  echo "Mega rows: $(docker exec "$DB" sh -lc 'mysql --batch --raw --skip-column-names -uroot -p"$MYSQL_ROOT_PASSWORD" onlyoffice -e "SELECT COUNT(*) FROM files_thirdparty_account WHERE LOWER(provider)=\"megas4\";"' 2>/dev/null | tr -d '\r')"
}

case "$MODE" in
  install)
    bash "$BASE" install
    bash "$LOOPFIX"
    status_v41
    ;;
  upgrade)
    bash "$LOOPFIX"
    status_v41
    ;;
  status)
    status_v41
    ;;
  *)
    echo "Usage: $0 {install|upgrade|status}" >&2
    exit 2
    ;;
esac
