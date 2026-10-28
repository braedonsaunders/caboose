#!/bin/sh
# Bitstream round trips through caboose_drv_video.so, for every case in
# tests/cases/<codec>.cases (or the codecs named on the command line).
#
# Each case is a reference clip encoded with ffmpeg. It is then decoded twice
# through the driver with `ffmpeg -hwaccel vaapi`:
#   passthrough  frames stay on the "GPU" (-hwaccel_output_format vaapi); the
#                driver forwards the rebuilt bitstream to a capture file, which
#                is decoded with ffmpeg's software decoder and must match the
#                source decode frame for frame, bit for bit.
#   readback     ffmpeg downloads every frame; the first readback switches the
#                stream to local decoding, and the downloaded frames must match
#                the source decode bit for bit.
# Case line: name | lavfi source | encoder args | container. Encoder args that
# start with "2pass" are run as a two-pass encode.
# Runs in the dev container (scripts/dev.sh tests/roundtrip.sh); needs Xvfb for a
# VA display unless DISPLAY is set.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
build=$(cd "$here" && cd "${CBVA_BUILD:-build}" && pwd)
work=${CBVA_WORK:-$(mktemp -d /tmp/cbva-rt.XXXXXX)}
codecs=${*:-h264 hevc vp9 av1}
if [ -z "${DISPLAY:-}" ]; then
  dpy=:$((90 + $$ % 900))
  Xvfb $dpy -screen 0 640x480x24 -nolisten tcp >/dev/null 2>&1 &
  xvfb=$!
  trap 'kill $xvfb 2>/dev/null' EXIT
  export DISPLAY=$dpy
  sleep 1
fi
export LIBVA_DRIVER_NAME=caboose LIBVA_DRIVERS_PATH="$build"
va="-init_hw_device vaapi=va:$DISPLAY -hwaccel vaapi -hwaccel_device va"
pass=0 fail=0

hashes() { grep -v '^#' "$1" | awk -F, '{gsub(/ /, "", $6); print $6}'; }

run_case() {
  name=$1 src=$2 enc=$3 ext=$4
  clip="$work/$name.$ext"
  # Encoder args starting with "2pass" run a first pass, then the second.
  case $enc in
    2pass*)
      enc=${enc#2pass}
      # shellcheck disable=SC2086
      ffmpeg -nostdin -hide_banner -loglevel error -y -f lavfi -i "$src" $enc -pass 1 \
        -passlogfile "$work/$name.pass" -f null - 2> "$work/$name.enc.log"
      enc="$enc -pass 2 -passlogfile $work/$name.pass" ;;
  esac
  # shellcheck disable=SC2086
  if ! ffmpeg -nostdin -hide_banner -loglevel error -y -f lavfi -i "$src" $enc "$clip" 2>> "$work/$name.enc.log"; then
    echo "FAIL $name: encode: $(head -1 "$work/$name.enc.log")"; fail=$((fail + 1)); return
  fi
  info=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,pix_fmt -of csv=p=0 "$clip")
  w=$(echo "$info" | cut -d, -f1) h=$(echo "$info" | cut -d, -f2) fmt=$(echo "$info" | cut -d, -f3)
  ffmpeg -nostdin -hide_banner -loglevel error -y -i "$clip" -f framemd5 "$work/$name.src.md5"
  hashes "$work/$name.src.md5" > "$work/$name.src"

  # Passthrough: rebuild, forward, decode in software.
  # shellcheck disable=SC2086
  if ! CABOOSE_VA_SINK="$work/$name.cap" ffmpeg -nostdin -hide_banner -loglevel error -y $va \
      -hwaccel_output_format vaapi -reinit_filter 0 -i "$clip" -f null - 2> "$work/$name.pass.log"; then
    echo "FAIL $name: passthrough decode: $(tail -1 "$work/$name.pass.log")"; fail=$((fail + 1)); return
  fi
  summary=$("$build/cbva-capture" split "$work/$name.cap" "$work/$name.fwd" | head -1)
  fwd=$(ls "$work/$name".fwd-1.* 2>/dev/null | head -1)
  if [ -z "$fwd" ]; then
    echo "FAIL $name: nothing forwarded"; fail=$((fail + 1)); return
  fi
  # H.264 and HEVC are forwarded at their coded size (VA has no crop); VP9 and AV1
  # frames carry their own size, which may change from frame to frame.
  case $fwd in *.ivf) crop=null ;; *) crop="crop=$w:$h:0:0" ;; esac
  ffmpeg -nostdin -hide_banner -loglevel error -y -i "$fwd" -vf "$crop" -pix_fmt "$fmt" \
    -f framemd5 "$work/$name.fwd.md5" 2> "$work/$name.fwd.log" || true
  hashes "$work/$name.fwd.md5" > "$work/$name.fwd"
  case $ext in
    ivf|webm|mkv)
      # VP9/AV1 hidden frames are output as soon as they are decoded, and also
      # when the source never shows them: every source frame must be there, and
      # the extras must be hidden frames.
      sort "$work/$name.src" > "$work/$name.src.sorted"; sort "$work/$name.fwd" > "$work/$name.fwd.sorted"
      missing=$(comm -23 "$work/$name.src.sorted" "$work/$name.fwd.sorted" | wc -l)
      extra=$(comm -13 "$work/$name.src.sorted" "$work/$name.fwd.sorted" | wc -l)
      hidden=$(echo "$summary" | sed -n 's/.*hidden=\([0-9]*\).*/\1/p')
      if [ "$missing" -eq 0 ] && [ "$extra" -le "${hidden:-0}" ]; then p1=ok; else p1="MISMATCH(missing=$missing,extra=$extra)"; fi ;;
    *)
      if cmp -s "$work/$name.src" "$work/$name.fwd"; then p1=ok
      else p1="MISMATCH($(wc -l < "$work/$name.src")/$(wc -l < "$work/$name.fwd"))"; fi ;;
  esac

  # Readback: the driver decodes locally; downloaded frames must be exact.
  # shellcheck disable=SC2086
  CABOOSE_VA_SINK="$work/$name.rb.cap" ffmpeg -nostdin -hide_banner -loglevel error -y $va -i "$clip" \
    -pix_fmt "$fmt" -f framemd5 "$work/$name.rb.md5" 2> "$work/$name.rb.log" || true
  hashes "$work/$name.rb.md5" > "$work/$name.rb"
  if cmp -s "$work/$name.src" "$work/$name.rb"; then p2=ok; else p2="MISMATCH($(wc -l < "$work/$name.rb"))"; fi

  if [ "$p1" = ok ] && [ "$p2" = ok ]; then pass=$((pass + 1)); s=PASS; else fail=$((fail + 1)); s=FAIL; fi
  printf '%s %-28s passthrough=%s readback=%s  %s\n' "$s" "$name" "$p1" "$p2" "$summary"
}

for codec in $codecs; do
  cases="$here/tests/cases/$codec.cases"
  [ -f "$cases" ] || continue
  while IFS='|' read -r name src enc ext; do
    case $name in ''|'#'*) continue ;; esac
    name=$(echo "$name" | xargs) src=$(echo "$src" | xargs) enc=$(echo "$enc" | xargs) ext=$(echo "$ext" | xargs)
    run_case "$name" "$src" "$enc" "$ext"
  done < "$cases"
done
echo "roundtrip: $pass passed, $fail failed (work: $work)"
[ "$fail" -eq 0 ]
