#!/usr/bin/env bash
# Real-guest check for media handoff: the installed extension loads through the system
# Chromium launcher, reports a playing video through the native host to the state file,
# and obeys pause and play-at-position commands. Run as root inside the computer:
#
#   docker exec -u root caboose-owner bash -s < guest/media-handoff/check.sh
#
# It starts its own headless Chromium as caboose with a throwaway HOME and profile and a
# local test video, so the owner's browser and state files are untouched. Set
# CABOOSE_CHECK_CHROMIUM_ARGS for extra flags (for example --no-sandbox where the
# container's seccomp policy has no namespace sandbox).
set -euo pipefail
extension=cklinclacpchpdgickgonlhnldfmkhbh
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ $(id -u) == 0 ]] || fail 'run as root'
[[ -x /opt/caboose/media-handoff/caboose-media-host.mjs ]] || fail 'native host is not installed'
grep -q "chrome-extension://$extension/" /etc/chromium/native-messaging-hosts/com.caboose.media.json || fail 'native host manifest does not allow the extension'
[[ -e /usr/share/chromium/extensions/caboose-media-handoff/manifest.json ]] || fail 'extension is not linked into /usr/share/chromium/extensions'
work=$(runuser -u caboose -- mktemp -d /tmp/caboose-media-check.XXXXXX)
pids=()
cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
state=$work/.cache/caboose/media.json
command_file=$work/.cache/caboose/media-command.json

# A local page with a 60 s WAV in a <video>: a plain http(s) source, so kind "video".
cat > "$work/serve.mjs" <<'JS'
import { createServer } from 'node:http'
const rate = 8000, seconds = 60, data = Buffer.alloc(rate * seconds)
for (let i = 0; i < data.length; i++) data[i] = 128 + Math.round(40 * Math.sin(i / 8))
const header = Buffer.alloc(44)
header.write('RIFF', 0); header.writeUInt32LE(36 + data.length, 4); header.write('WAVEfmt ', 8)
header.writeUInt32LE(16, 16); header.writeUInt16LE(1, 20); header.writeUInt16LE(1, 22)
header.writeUInt32LE(rate, 24); header.writeUInt32LE(rate, 28); header.writeUInt16LE(1, 32)
header.writeUInt16LE(8, 34); header.write('data', 36); header.writeUInt32LE(data.length, 40)
const wav = Buffer.concat([header, data])
const server = createServer((request, response) => {
  if (request.url === '/tone.wav') {
    const range = /bytes=(\d+)-(\d*)/.exec(request.headers.range ?? '')
    const start = range ? Number(range[1]) : 0, end = range && range[2] ? Number(range[2]) : wav.length - 1
    response.writeHead(range ? 206 : 200, { 'content-type': 'audio/wav', 'accept-ranges': 'bytes', 'content-length': end - start + 1,
      ...(range ? { 'content-range': `bytes ${start}-${end}/${wav.length}` } : {}) })
    return response.end(wav.subarray(start, end + 1))
  }
  response.writeHead(200, { 'content-type': 'text/html' })
  response.end('<!doctype html><title>Caboose check video</title><video src="/tone.wav" controls autoplay></video>')
})
server.listen(0, '127.0.0.1', () => console.log(server.address().port))
JS
runuser -u caboose -- node "$work/serve.mjs" > "$work/port" &
pids+=($!)
for _ in $(seq 1 50); do [[ -s $work/port ]] && break; sleep 0.1; done
port=$(cat "$work/port")
[[ -n $port ]] || fail 'test page server did not start'

# shellcheck disable=SC2086
runuser -u caboose -- env HOME="$work" /usr/bin/chromium --headless=new --user-data-dir="$work/profile" \
  --autoplay-policy=no-user-gesture-required --no-first-run ${CABOOSE_CHECK_CHROMIUM_ARGS:-} \
  "http://127.0.0.1:$port/" > "$work/chromium.log" 2>&1 &
pids+=($!)

field() { node -e 'try { const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); console.log(JSON.stringify(s[process.argv[2]])) } catch { console.log("") }' "$state" "$1"; }
wait_for() {
  local description=$1 test=$2
  for _ in $(seq 1 60); do eval "$test" && return 0; sleep 0.5; done
  echo "--- chromium log" >&2; tail -n 30 "$work/chromium.log" >&2
  fail "$description"
}
wait_for 'no playing video reached media.json (extension or native host not loaded)' '[[ -s $state && $(field paused) == false ]]'
[[ $(field kind) == '"video"' ]] || fail "kind is $(field kind), expected video"
[[ $(field src) == "\"http://127.0.0.1:$port/tone.wav\"" ]] || fail "src is $(field src)"
id=$(field id | tr -d '"')
[[ $id =~ ^[A-Za-z0-9._-]{1,64}$ ]] || fail "id $id does not match the contract"
echo "ok: playing video reported as $id"

write_command() {
  runuser -u caboose -- sh -c 'umask 077; printf %s "$2" > "$1.tmp" && mv -f "$1.tmp" "$1"' sh "$command_file" "$1"
}
write_command "{\"seq\":$(date +%s%3N),\"id\":\"$id\",\"action\":\"pause\"}"
wait_for 'pause command was not obeyed' '[[ $(field paused) == true ]]'
echo 'ok: paused by command'
write_command "{\"seq\":$(( $(date +%s%3N) + 1 )),\"id\":\"$id\",\"action\":\"play\",\"position\":30}"
wait_for 'play-at-position command was not obeyed' '[[ $(field paused) == false ]] && node -e "process.exit(Number(process.argv[1]) >= 30 ? 0 : 1)" "$(field position)"'
echo 'ok: resumed at the requested position'

kill "${pids[1]}"
wait_for 'media.json was not cleared when the browser closed' '[[ ! -e $state ]]'
echo 'ok: state cleared when the browser closed'
echo 'media handoff check passed'
