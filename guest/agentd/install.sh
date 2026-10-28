#!/bin/sh
# Install caboose-agentd into the guest image at /opt/caboose/agentd. Run as root inside the
# image build, after Node and npm. The runtime dependencies are the exact versions pinned in
# package.json, and their registry integrity is checked before npm installs them.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
dest=/opt/caboose/agentd
install -d -m 0755 "$dest"
install -m 0755 "$here/caboose-agentd.mjs" "$dest/.caboose-agentd.mjs.tmp"
mv -f "$dest/.caboose-agentd.mjs.tmp" "$dest/caboose-agentd.mjs"
install -m 0755 "$here/agent-tools.mjs" "$dest/.agent-tools.mjs.tmp"
mv -f "$dest/.agent-tools.mjs.tmp" "$dest/agent-tools.mjs"
# Only what runs in the guest: no test tooling.
node -e '
const source = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))
const runtime = { name: source.name, version: source.version, private: true, type: "module", dependencies: source.dependencies }
require("fs").writeFileSync(process.argv[2], JSON.stringify(runtime, null, 2) + "\n")
' "$here/package.json" "$dest/package.json"
check() {
  [ "$(npm view "$1" dist.integrity)" = "$2" ] || { echo "Unexpected registry integrity for $1" >&2; exit 1; }
}
# Existing images already have the pinned dependencies. Upgrade only the runner in that case.
if ! node -e '
const fs = require("fs"), path = require("path")
const base = process.argv[1]
const expected = JSON.parse(fs.readFileSync(path.join(base, "package.json"))).dependencies
for (const [name, version] of Object.entries(expected)) {
  if (JSON.parse(fs.readFileSync(path.join(base, "node_modules", name, "package.json"))).version !== version) process.exit(1)
}
' "$dest" 2>/dev/null; then
check '@agentclientprotocol/sdk@2.0.2' 'sha512-jLywRB42hZMRMc4aUgt0uRjkY9FQnMdybv4XgLl+ddi75QuJn8Vbl0+CHcVHJDC0+WDfi1KQXRWtHaR5vp6gHw=='
check 'zod@4.6.7' 'sha512-g8W2D2kU6a8untc053fX1uVBKzM7yqAxW/3zwk83+6RyF2+SKOuV+c0wBDhUwzV1PaGapmZH+rmcUzPf+3CGwg=='
(cd "$dest" && npm install --omit=dev --no-audit --no-fund --loglevel=error)
fi
chmod -R a+rX "$dest"
node "$dest/caboose-agentd.mjs" --version >/dev/null
