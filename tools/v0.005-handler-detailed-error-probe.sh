#!/usr/bin/env bash
set -Eeuo pipefail

# BRIMSTONE CUSTOM CODE — one-shot detailed ASP.NET handler error capture.
# Purpose:
#   * install the existing v0.005 explicit handler mapping
#   * force customErrors=RemoteOnly so a localhost probe may see the real exception
#   * restart ONLY CommunityServer, capture the full mapped-handler response
#   * restore the exact pre-test Web.config and restart CommunityServer cleanly
#
# No connector DLL, database content, UI bundle, or credentials are modified.

REPO="${REPO:-/opt/mega-cloud-connectors-for-onlyoffice}"
C="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
DB="${MYSQL_CONTAINER:-onlyoffice-mysql-server}"
WEB="/var/www/onlyoffice/WebStudio/Web.config"
MAPSCRIPT="$REPO/tools/v0.005-handler-map.sh"
EXPECTED_DLL="62bdff5b75ab9db37108a6f772a92240805879f0cf400bb8c2813d2aa68b679f"
LIVE_DLL="/var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll"
ROUTE="/Products/Files/HttpHandlers/brimstone-megas4.ashx"

installed=0
cleanup_running=0

fail(){ echo "FAIL: $*" >&2; exit 1; }
live_dll_hash(){ docker exec "$C" sha256sum "$LIVE_DLL" | awk '{print $1}'; }
mysql_restarts(){ docker inspect -f '{{.RestartCount}}' "$DB"; }
mysql_started(){ docker inspect -f '{{.State.StartedAt}}' "$DB"; }

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

restore(){
  local rc=$?
  (( cleanup_running == 0 )) || exit "$rc"
  cleanup_running=1
  trap - EXIT INT TERM
  set +e

  if (( installed == 1 )); then
    echo
    echo "============================================================"
    echo " CLEANUP — RESTORING ORIGINAL WEB.CONFIG"
    echo "============================================================"
    bash "$MAPSCRIPT" rollback
    echo "Restarting CommunityServer only to guarantee clean restored state..."
    docker restart "$C" >/dev/null
    wait_ready "restored CommunityServer" || echo "WARN: restored CommunityServer did not report warmup complete within 240s"
  fi

  echo
  echo "=== CLEANUP SAFETY STATE ==="
  echo "Connector DLL : $(live_dll_hash 2>/dev/null || echo unavailable)"
  echo "MySQL restarts: $(mysql_restarts 2>/dev/null || echo unavailable)"
  echo "MySQL Started : $(mysql_started 2>/dev/null || echo unavailable)"

  exit "$rc"
}
trap restore EXIT INT TERM

[[ -d "$REPO/.git" ]] || fail "repo missing: $REPO"
[[ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" == "v0.005-typed-creds" ]] || fail "checkout v0.005-typed-creds first"
[[ -z "$(git -C "$REPO" status --porcelain)" ]] || fail "repo worktree is not clean"
[[ -x "$MAPSCRIPT" || -f "$MAPSCRIPT" ]] || fail "missing $MAPSCRIPT"
command -v python3 >/dev/null 2>&1 || fail "host python3 is required"
[[ "$(docker inspect -f '{{.State.Running}}' "$C")" == "true" ]] || fail "CommunityServer is not running"
[[ "$(docker inspect -f '{{.State.Running}}' "$DB")" == "true" ]] || fail "MySQL is not running"
[[ "$(live_dll_hash)" == "$EXPECTED_DLL" ]] || fail "connector DLL is not the locked baseline"

mysql_before="$(mysql_restarts)"
mysql_started_before="$(mysql_started)"

echo "============================================================"
echo " BRIMSTONE v0.005 — DETAILED HANDLER ERROR PROBE"
echo "============================================================"
echo "Connector DLL        : $(live_dll_hash)"
echo "MySQL restart count  : $mysql_before"
echo "MySQL StartedAt      : $mysql_started_before"

echo
echo "=== HANDLER MAP PRE-FLIGHT ==="
bash "$MAPSCRIPT" preflight

echo
echo "=== INSTALL TEMPORARY HANDLER MAP ==="
bash "$MAPSCRIPT" install
installed=1

# Copy the now-mapped Web.config to host, minimally force customErrors=RemoteOnly,
# validate XML, then install it back with original ownership/mode. The handler-map
# rollback backup remains the authoritative exact restore point.
src="$(mktemp)"
patched="$(mktemp)"
trap 'rm -f "$src" "$patched"' RETURN

docker cp "$C:$WEB" "$src" >/dev/null
python3 - "$src" "$patched" <<'PY'
from pathlib import Path
import re, sys, xml.etree.ElementTree as ET

src, dst = map(Path, sys.argv[1:3])
data = src.read_bytes()
newline = b'\r\n' if b'\r\n' in data else b'\n'

# Work in latin-1 for byte-preserving 1:1 text manipulation of ASCII XML markup.
text = data.decode('latin-1')
pat = re.compile(r'<customErrors\b[^>]*>', re.I)
matches = list(pat.finditer(text))
if len(matches) > 1:
    raise SystemExit('expected at most one <customErrors> opening element')

if matches:
    tag = matches[0].group(0)
    if re.search(r'\bmode\s*=\s*["\'][^"\']*["\']', tag, re.I):
        newtag = re.sub(r'\bmode\s*=\s*(["\'])[^"\']*\1', 'mode="RemoteOnly"', tag, count=1, flags=re.I)
    else:
        newtag = tag[:-1] + ' mode="RemoteOnly">'
    text = text[:matches[0].start()] + newtag + text[matches[0].end():]
else:
    sw = re.search(r'<system\.web\b[^>]*>', text, re.I)
    if not sw:
        raise SystemExit('no <system.web> opening element found')
    insertion = newline.decode('latin-1') + '    <customErrors mode="RemoteOnly" />'
    text = text[:sw.end()] + insertion + text[sw.end():]

out = text.encode('latin-1')
dst.write_bytes(out)
ET.parse(dst)
print('PASS: temporary Web.config XML parses')
PY

read -r uid gid mode < <(docker exec "$C" stat -c '%u %g %a' "$WEB")
docker cp "$patched" "$C:/tmp/brimstone-Web.config.debug" >/dev/null
docker exec "$C" install -o "$uid" -g "$gid" -m "$mode" /tmp/brimstone-Web.config.debug "$WEB"
docker exec "$C" rm -f /tmp/brimstone-Web.config.debug

echo
echo "=== TEMPORARY LOCAL-DETAIL MODE ==="
docker exec "$C" sh -lc "grep -n -B 1 -A 1 -i 'customErrors' '$WEB' || true"
docker exec "$C" sh -lc "grep -n -F 'Products/Files/HttpHandlers/brimstone-megas4.ashx' '$WEB' || true"

echo
echo "=== CONTROLLED COMMUNITYSERVER RESTART ==="
docker restart "$C" >/dev/null
wait_ready "diagnostic CommunityServer" || fail "CommunityServer did not complete warmup"

[[ "$(mysql_restarts)" == "$mysql_before" ]] || fail "MySQL restart count changed during diagnostic"
[[ "$(mysql_started)" == "$mysql_started_before" ]] || fail "MySQL StartedAt changed during diagnostic"
[[ "$(live_dll_hash)" == "$EXPECTED_DLL" ]] || fail "connector DLL changed during diagnostic"

headers="$(mktemp)"
body="$(mktemp)"
trap 'rm -f "$headers" "$body"' RETURN

code="$(docker exec "$C" sh -lc "curl -sS -D /tmp/brimstone-detail.headers -o /tmp/brimstone-detail.body -w '%{http_code}' -X POST --data-urlencode 'action=list-buckets' --data-urlencode 'source=manual' --data-urlencode 'accessKey=x' --data-urlencode 'secretKey=y' 'http://127.0.0.1$ROUTE' || true")"
docker cp "$C:/tmp/brimstone-detail.headers" "$headers" >/dev/null 2>&1 || true
docker cp "$C:/tmp/brimstone-detail.body" "$body" >/dev/null 2>&1 || true
docker exec "$C" rm -f /tmp/brimstone-detail.headers /tmp/brimstone-detail.body >/dev/null 2>&1 || true

echo
echo "============================================================"
echo " DETAILED ROUTE RESULT"
echo "============================================================"
echo "HTTP: ${code:-unknown}"
echo
echo "--- RESPONSE HEADERS ---"
sed -n '1,40p' "$headers" || true

echo
echo "--- RAW BODY — FIRST 80 LINES ---"
sed -n '1,80p' "$body" || true

echo
echo "--- HTML/TEXT ERROR SUMMARY ---"
python3 - "$body" <<'PY'
from html.parser import HTMLParser
from pathlib import Path
import html, re, sys

raw = Path(sys.argv[1]).read_text(errors='replace')
if not raw.strip():
    print('(empty body)')
    raise SystemExit
if raw.lstrip().startswith('{'):
    print(raw.strip())
    raise SystemExit

class P(HTMLParser):
    def __init__(self):
        super().__init__()
        self.skip = 0
        self.parts = []
    def handle_starttag(self, tag, attrs):
        if tag.lower() in ('style','script'):
            self.skip += 1
        elif tag.lower() in ('br','p','div','h1','h2','h3','pre','li','tr') and not self.skip:
            self.parts.append('\n')
    def handle_endtag(self, tag):
        if tag.lower() in ('style','script') and self.skip:
            self.skip -= 1
        elif tag.lower() in ('p','div','h1','h2','h3','pre','li','tr') and not self.skip:
            self.parts.append('\n')
    def handle_data(self, data):
        if not self.skip:
            self.parts.append(data)

p = P(); p.feed(raw)
text = html.unescape(''.join(p.parts)).replace('\r','')
lines = []
for line in text.split('\n'):
    line = re.sub(r'[ \t]+', ' ', line).strip()
    if line:
        lines.append(line)
for line in lines[:220]:
    print(line)
PY

echo
echo "--- KEY EXCEPTION PHRASES ---"
grep -Eio -m 40 \
  '([A-Za-z0-9_.]+Exception[^<]{0,300}|Could not load[^<]{0,300}|Could not resolve[^<]{0,300}|does not implement[^<]{0,300}|Failed to load[^<]{0,300}|handler[^<]{0,300}|configuration[^<]{0,300})' \
  "$body" 2>/dev/null || true

echo
echo "PASS: diagnostic capture complete; EXIT cleanup will restore the exact original Web.config."
