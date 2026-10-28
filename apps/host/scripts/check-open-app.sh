#!/bin/sh
# Run with a running computer, an installed catalog app and a compatible local document.
set -eu
: "${CABOOSE_URL:?Set CABOOSE_URL}"
: "${CABOOSE_OWNER_TOKEN:?Set CABOOSE_OWNER_TOKEN}"
: "${CABOOSE_CHECK_FILE:?Set CABOOSE_CHECK_FILE to a local document}"
: "${CABOOSE_CHECK_APP:?Set CABOOSE_CHECK_APP to an installed desktop id}"
folder="Caboose-open-check-$(date +%s)-$$"
name=$(basename "$CABOOSE_CHECK_FILE")
folder_query=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.urlencode({"path":sys.argv[1]}))' "$folder")
file_query=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.urlencode({"path":sys.argv[1]}))' "$folder/$name")
curl -fsS -X POST -H "Authorization: Bearer $CABOOSE_OWNER_TOKEN" "$CABOOSE_URL/v1/fs/mkdir?$folder_query" >/dev/null
curl -fsS -X PUT -H "Authorization: Bearer $CABOOSE_OWNER_TOKEN" -H 'If-None-Match: *' --data-binary "@$CABOOSE_CHECK_FILE" "$CABOOSE_URL/v1/fs/content?$file_query" >/dev/null
python3 -c 'import json,sys; print(json.dumps({"path":sys.argv[1],"app":sys.argv[2]}))' "$folder/$name" "$CABOOSE_CHECK_APP" | curl -fsS -X POST -H "Authorization: Bearer $CABOOSE_OWNER_TOKEN" -H 'Content-Type: application/json' --data-binary @- "$CABOOSE_URL/v1/fs/open"
printf '\nCheck the owner display: the selected application should show the document. The test copy remains in %s.\n' "$folder"
