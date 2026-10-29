#!/usr/bin/env bash
# Only in the disposable check container, with no mounted user home or credentials.
set -euo pipefail
for spec in 'claude-desktop 4.29.0 com.anthropic.Claude.desktop Claude' 'chatgpt 26.1023.51421 chatgpt.desktop chatgpt'; do
  read -r package version desktop window_class <<< "$spec"
  [[ $(dpkg-query -W -f='${Status} ${Version}' "$package") == "install ok installed $version" ]]
  desktop-file-validate "/usr/share/applications/$desktop"
  # One fresh session per client; a visible application window is required, not
  # merely a surviving process. Container teardown owns all child processes.
  runuser -u caboose -- env DESKTOP="$desktop" WINDOW_CLASS="$window_class" \
    xvfb-run -a dbus-run-session -- bash -euo pipefail -c '
      gio launch "/usr/share/applications/$DESKTOP" >"/tmp/$DESKTOP.log" 2>&1 &
      for attempt in $(seq 1 90); do
        if xdotool search --onlyvisible --class "$WINDOW_CLASS" >/tmp/window-id 2>/dev/null; then
          sleep 3
          xdotool getwindowname "$(head -n1 /tmp/window-id)"
          echo "PASS: $DESKTOP opened a visible window with its vendor launcher"
          exit 0
        fi
        sleep 1
      done
      cat "/tmp/$DESKTOP.log"
      exit 1
    '
done
