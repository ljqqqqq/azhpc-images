#!/bin/bash
set -e

DEST_DIR=/opt/azurehpc/tools
mkdir -p $DEST_DIR

KVP_SOURCE_FILE=/tmp/kvp_client.c

curl -fsSL \
    "https://raw.githubusercontent.com/microsoft/lis-test/master/WS2012R2/lisa/tools/KVP/kvp_client.c" \
    -o "$KVP_SOURCE_FILE"
install -m 0644 "$KVP_SOURCE_FILE" "$DEST_DIR/kvp_client.c"

gcc \
    -std=gnu89 \
    -Wno-implicit-int \
    -Wno-implicit-function-declaration \
    "$DEST_DIR/kvp_client.c" \
    -o "$DEST_DIR/kvp_client"

rm -f "$KVP_SOURCE_FILE"
