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
#   phone        as passthrough, but the stream goes to the phone over the media
#                connection (docs/gpu-media.md), with tools/cbva-phone as the phone
#                and the consumer stub preloaded; the units it receives must decode
#                to the source, and it must see no contract violation.
#   phone-rb     as readback with the phone connected: the first readback moves the
#                stream from the phone to local decoding, exact as before.
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

# Splits CAPTURE into PREFIX-* streams, decodes the first in software and compares
# it with the source decode ($work/$name.src): $result is ok or what differs, and
# $summary the first stream's summary line.
# it with the source decode ($work/$name.src); prints ok or what differs, and sets
# $summary to the capture's first stream summary.
forwarded() {
  summary=$("$build/cbva-capture" split "$1" "$2" | head -1)
  fwd=$(ls "$2"-1.* 2>/dev/null | head -1)
  if [ -z "$fwd" ]; then result=NOTHING-FORWARDED; return; fi
  # H.264 and HEVC are forwarded at their coded size (VA has no crop); VP9 and AV1
  # frames carry their own size, which may change from frame to frame.
  case $fwd in *.ivf) crop=null ;; *) crop="crop=$w:$h:0:0" ;; esac
  ffmpeg -nostdin -hide_banner -loglevel error -y -i "$fwd" -vf "$crop" -pix_fmt "$fmt" \
    -f framemd5 "$2.md5" 2> "$2.log" || true
  hashes "$2.md5" > "$2.hashes"
  case $ext in
    ivf|webm|mkv)
      # VP9/AV1 hidden frames are output as soon as they are decoded, and also
      # when the source never shows them: every source frame must be there, and
      # the extras must be hidden frames.
      sort "$work/$name.src" > "$2.src.sorted"; sort "$2.hashes" > "$2.sorted"
      missing=$(comm -23 "$2.src.sorted" "$2.sorted" | wc -l)
      extra=$(comm -13 "$2.src.sorted" "$2.sorted" | wc -l)
      hidden=$(echo "$summary" | sed -n 's/.*hidden=\([0-9]*\).*/\1/p')
      if [ "$missing" -eq 0 ] && [ "$extra" -le "${hidden:-0}" ]; then result=ok; else result="MISMATCH(missing=$missing,extra=$extra)"; fi ;;
    *)
      if cmp -s "$work/$name.src" "$2.hashes"; then result=ok
      else result="MISMATCH($(wc -l < "$work/$name.src")/$(wc -l < "$2.hashes"))"; fi ;;
  esac
}

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
  forwarded "$work/$name.cap" "$work/$name.fwd"; p1=$result; pass_summary=$summary

  # Phone: the same frames, forwarded over the media connection.
  "$build/cbva-phone" "$work/$name.sock" "$work/$name.ph.cap" > "$work/$name.ph.out" 2>&1 &
  phone=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$work/$name.sock" ] && break; sleep 0.1; done
  # shellcheck disable=SC2086
  CABOOSE_GFXSTREAM_SOCKET="$work/$name.sock" LD_PRELOAD="$build/libvulkan_gfxstream-stub.so" \
    ffmpeg -nostdin -hide_banner -loglevel error -y $va -hwaccel_output_format vaapi -reinit_filter 0 \
    -i "$clip" -f null - 2> "$work/$name.ph.log" || true
  kill -TERM $phone; wait $phone 2>/dev/null && ph_ok=1 || ph_ok=0
  forwarded "$work/$name.ph.cap" "$work/$name.ph"; p3=$result; summary=$pass_summary
  # The stand-in phone decodes H.264 at 8 bits only, like a real one: the driver does
  # not offer High 10, and ffmpeg decodes it in software.
  case $codec/$fmt in
    h264/*10*) if [ "$p3" = NOTHING-FORWARDED ]; then p3=ok; else p3="OFFERED($p3)"; fi ;;
  esac
  [ "$ph_ok" = 1 ] || p3="VIOLATION($(tail -1 "$work/$name.ph.out"))"

  # Phone, read back: the stream moves from the phone to local decoding.
  "$build/cbva-phone" "$work/$name.sock" "$work/$name.phrb.cap" > "$work/$name.phrb.out" 2>&1 &
  phone=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$work/$name.sock" ] && break; sleep 0.1; done
  # shellcheck disable=SC2086
  CABOOSE_GFXSTREAM_SOCKET="$work/$name.sock" LD_PRELOAD="$build/libvulkan_gfxstream-stub.so" \
    ffmpeg -nostdin -hide_banner -loglevel error -y $va -i "$clip" \
    -pix_fmt "$fmt" -f framemd5 "$work/$name.phrb.md5" 2> "$work/$name.phrb.log" || true
  kill -TERM $phone; wait $phone 2>/dev/null || true
  hashes "$work/$name.phrb.md5" > "$work/$name.phrb"
  if cmp -s "$work/$name.src" "$work/$name.phrb"; then p4=ok; else p4="MISMATCH($(wc -l < "$work/$name.phrb"))"; fi

  # Readback: the driver decodes locally; downloaded frames must be exact.
  # shellcheck disable=SC2086
  CABOOSE_VA_SINK="$work/$name.rb.cap" ffmpeg -nostdin -hide_banner -loglevel error -y $va -i "$clip" \
    -pix_fmt "$fmt" -f framemd5 "$work/$name.rb.md5" 2> "$work/$name.rb.log" || true
  hashes "$work/$name.rb.md5" > "$work/$name.rb"
  if cmp -s "$work/$name.src" "$work/$name.rb"; then p2=ok; else p2="MISMATCH($(wc -l < "$work/$name.rb"))"; fi

  if [ "$p1" = ok ] && [ "$p2" = ok ] && [ "$p3" = ok ] && [ "$p4" = ok ]; then pass=$((pass + 1)); s=PASS
  else fail=$((fail + 1)); s=FAIL; fi
  printf '%s %-28s passthrough=%s readback=%s phone=%s phone-rb=%s  %s\n' "$s" "$name" "$p1" "$p2" "$p3" "$p4" "$summary"
}

for codec in $codecs; do
  cases="$here/tests/cases/$codec.cases"
  [ -f "$cases" ] || continue
  while IFS='|' read -r name src enc ext; do
    case $name in ''|'#'*) continue ;; esac
    name=$(echo "$name" | xargs) src=$(echo "$src" | xargs) enc=$(echo "$enc" | xargs) ext=$(echo "$ext" | xargs)
    if [ -n "${CBVA_CASES:-}" ]; then
      case " $CBVA_CASES " in *" $name "*) ;; *) continue ;; esac
    fi
    run_case "$name" "$src" "$enc" "$ext"
  done < "$cases"
done
echo "roundtrip: $pass passed, $fail failed (work: $work)"
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]
