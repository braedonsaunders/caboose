#!/bin/sh
# A "shell" for terminal checks: writes the first line typed into it to $CABOOSE_TYPED.
IFS= read -r line
printf '%s\n' "$line" > "${CABOOSE_TYPED:?}"
sleep 30
