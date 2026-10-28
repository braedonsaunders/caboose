#!/bin/sh
# Run with a running computer, an installed catalog app and a compatible local document.
set -eu
: "${CABOOSE_URL:?Set CABOOSE_URL}"
: "${CABOOSE_OWNER_TOKEN:?Set CABOOSE_OWNER_TOKEN}"
: "${CABOOSE_CHECK_FILE:?Set CABOOSE_CHECK_FILE to a local document}"
: "${CABOOSE_CHECK_APP:?Set CABOOSE_CHECK_APP to an installed desktop id}"
folder="Caboose-open-check-$(date +%s)-$$"
name=$(basename "$CABOOSE_CHECK_FILE")
case "$name" in *"\"*|*'"'*|*'/'*) echo 'Unsupported filename for this check' >&2; exit 1;; esac
curl -fsS -X POST -H "Authorization: Bearer $CABOOSE_OWNER_TOKEN" --get --data-urlencode "path=$folder" "$CABOOSE_URL/v1/fs/mkdir" >/dev/null
curl -fsS -X PUT -H "Authorization: Bearer $CABOOSE_OWNER_TOKEN" -H 'If-None-Match: *' --data-binary "@$CABOOSE_CHECK_FILE" --get --data-urlencode "path=$folder/$name" "$CABOOSE_URL/v1/fs/content" >/dev/null
python3 -c 'import json,sys; print(json.dumps({"path":sys.argv[1],"app":sys.argv[2]}))' "$folder/$name" "$CABOOSE_CHECK_APP" | curl -fsS -X POST -H "Authorization: Bearer $CABOOSE_OWNER_TOKEN" -H 'Content-Type: application/json' --data-binary @- "$CABOOSE_URL/v1/fs/open"
printf '\nCheck the owner display: the selected application should show the document. The test copy remains in %s.\n' "$folder"
