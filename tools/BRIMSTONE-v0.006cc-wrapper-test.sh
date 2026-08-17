#!/usr/bin/env bash
set -Eeuo pipefail

C=onlyoffice-community-server

HOME_DIR=/var/lib/brimstone/mega-cloud/providers/brimstone-v0002-test1/home
SOCKET_NAME=brimstone-megacc-brimstone-v0002-test1.socket
INSTALL=/opt/brimstone/mega-cloud/bin/brimstone-megacc-exec

echo "============================================================"
echo " v0.006cc MEGACMD WRAPPER — STANDALONE TEST"
echo "============================================================"

docker exec "$C" mkdir -p /opt/brimstone/mega-cloud/bin

docker cp \
    src/mega-cloud/runtime/brimstone-megacc-exec \
    "$C:$INSTALL"

docker exec "$C" chmod 0755 "$INSTALL"

echo
echo "=== WRAPPER SYNTAX ==="

docker exec "$C" bash -n "$INSTALL"
echo "PASS"

echo
echo "=== WHOAMI THROUGH WRAPPER ==="

docker exec \
    -u 104:107 \
    -e HOME="$HOME_DIR" \
    -e MEGACMD_SOCKET_NAME="$SOCKET_NAME" \
    -e LD_LIBRARY_PATH=/opt/brimstone/mega-cloud/megacmd/opt/megacmd/lib \
    "$C" \
    "$INSTALL" whoami

echo
echo "=== ROOT THROUGH WRAPPER ==="

docker exec \
    -u 104:107 \
    -e HOME="$HOME_DIR" \
    -e MEGACMD_SOCKET_NAME="$SOCKET_NAME" \
    -e LD_LIBRARY_PATH=/opt/brimstone/mega-cloud/megacmd/opt/megacmd/lib \
    "$C" \
    "$INSTALL" ls /

echo
echo "=== TEN CALL WRAPPER SOAK ==="

for N in $(seq 1 10); do

    docker exec \
        -u 104:107 \
        -e HOME="$HOME_DIR" \
        -e MEGACMD_SOCKET_NAME="$SOCKET_NAME" \
        -e LD_LIBRARY_PATH=/opt/brimstone/mega-cloud/megacmd/opt/megacmd/lib \
        "$C" \
        "$INSTALL" whoami \
        >/dev/null

    echo "call $N: PASS"
done

echo
echo "============================================================"
echo " PASS — v0.006cc WRAPPER BASIC RUNTIME"
echo "============================================================"
echo
echo "NOTE:"
echo "The ONLYOFFICE DLL has NOT been changed."
echo "The live connector still uses direct mega-exec."
echo "This test exercises the wrapper independently."
