case ${DISPLAY:-} in
  :100|:100.*)
    if [ -z "${PULSE_SERVER:-}" ] && command -v xprop >/dev/null 2>&1; then
      caboose_pulse_server=$(xprop -root -notype PULSE_SERVER 2>/dev/null | sed -n 's/^PULSE_SERVER = "\(.*\)"$/\1/p')
      if [ -n "$caboose_pulse_server" ]; then export PULSE_SERVER="$caboose_pulse_server"; fi
      unset caboose_pulse_server
    fi ;;
esac
