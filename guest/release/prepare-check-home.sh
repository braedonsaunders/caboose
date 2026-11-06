#!/bin/sh
# The sealing check's own home in a computer (check.conf's chaos_home), made when it is
# missing, so that a recreated computer seals without anything placed by hand (README.md,
# "The check's home"):
#
#   sh guest/release/prepare-check-home.sh COMPUTER HOME TRIANGLE DISPLAY_ENV
#
# HOME gets a Steam Flatpak profile of its own: Steam's client is downloaded by starting
# Steam once with HOME, presenting on the display DISPLAY_ENV names (a seat of the check's own,
# never the owner's), until its web helper runs, then Steam is shut down. TRIANGLE, DXVK's
# d3d11 triangle.exe in the computer, is copied to the profile's caboose-bench. A home that
# already has both is left as it is. Only processes running from HOME are ever ended.
set -eu
# Nothing a check starts leaves a core dump, and nothing it starts crowds out the rest of the
# host: crashes are expected while the checks end programs (the host turns each into a capture of
# several gigabytes), and the host is shared. Every container this script runs gets a core
# limit of 0 and, unless it sets its own, at most 4 CPUs and 6 GB of memory; every command it
# runs in a computer runs at the lowest priority with a core limit of 0 (prlimit and nice,
# before the command).
ulimit -c 0
renice -n 19 $$ > /dev/null 2>&1 || :
docker() {
  if [ "${1:-}" = run ]; then
    shift
    case " $* " in *" --cpus "*) set -- --ulimit core=0 "$@" ;; *) set -- --ulimit core=0 --cpus 4 "$@" ;; esac
    case " $* " in *" --memory "*) ;; *) set -- --memory 6g "$@" ;; esac
    command docker run "$@"; return
  fi
  if [ "${1:-}" != exec ]; then command docker "$@"; return; fi
  shift
  _count=$# _seen=0 _state=option
  while [ "$_seen" -lt "$_count" ]; do
    _arg=$1; shift; _seen=$((_seen + 1))
    case $_state in
      option) case $_arg in
        -u|-e|-w|--user|--env|--workdir) set -- "$@" "$_arg" "$1"; shift; _seen=$((_seen + 1)) ;;
        -*) set -- "$@" "$_arg" ;;
        *) set -- "$@" "$_arg" prlimit --core=0:0 -- nice -n 19; _state=command ;;
      esac ;;
      command) set -- "$@" "$_arg" ;;
    esac
  done
  command docker exec "$@"
}
[ $# -eq 4 ] || { sed -n '4,13p' "$0" >&2; exit 2; }
computer=$1 home=$2 triangle=$3 display=$4
case $home in /var/tmp/?*|/var/lib/?*|/tmp/?*) ;; *) echo "HOME must be a directory of the check's own under /var/tmp, /var/lib or /tmp" >&2; exit 2;; esac
app=$home/.var/app/com.valvesoftware.Steam
helper=$app/.local/share/Steam/ubuntu12_64/steamwebhelper
bench=$app/caboose-bench
# A pattern for HOME's processes that the shell running it does not match itself.
own="[${home%"${home#?}"}]${home#?}/"
run() { docker exec "$computer" sh -c "$1"; }
if run "[ -x '$helper' ] && [ -f '$bench/triangle.exe' ]"; then
  echo "PASS check home: $home has its Steam profile and triangle"
  exit 0
fi
run "mkdir -p '$home' && chown caboose '$home'"
if ! run "[ -x '$helper' ]"; then
  docker exec -d -u caboose "$computer" sh -c "set -a; . '$display'; set +a; export HOME='$home'; \
    exec dbus-run-session -- timeout 1200 flatpak run com.valvesoftware.Steam > '$home/steam-bootstrap.log' 2>&1"
  i=0
  until run "[ -x '$helper' ] && pgrep -f '[s]teamwebhelper' -a | grep -q '$home/'"; do
    i=$((i + 1))
    [ $i -le 240 ] || { run "pkill -TERM -f '$own'" || true; echo "FAIL check home: Steam's client never started in $home" >&2; exit 1; }
    sleep 5
  done
  docker exec -u caboose "$computer" sh -c "set -a; . '$display'; set +a; export HOME='$home'; \
    timeout 60 flatpak run com.valvesoftware.Steam -shutdown > /dev/null 2>&1" || true
  i=0; while run "pgrep -f '$own' > /dev/null"; do
    i=$((i + 1)); [ $i -le 30 ] || { run "pkill -KILL -f '$own'" || true; break; }; sleep 2; done
fi
run "mkdir -p '$bench' && cp '$triangle' '$bench/triangle.exe' && chown -R caboose '$app'"
echo "PASS check home: $home made with Steam's client and the triangle"
