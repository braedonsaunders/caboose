#!/bin/sh
# Install caboose-game-run and the game bundles Caboose ships (docs/game-handoff.md).
set -eu
src=$(cd "$(dirname "$0")" && pwd)
install -Dm755 "$src/caboose-game-run" /usr/local/bin/caboose-game-run
# Replace the shipped bundles as a whole, so a bundle that is no longer shipped goes too.
games=/usr/local/share/caboose/games
rm -rf "$games.new"
install -d -m 0755 "$games.new"
for bundle in "$src"/games/*/; do
  cp -R "$bundle" "$games.new/$(basename "$bundle")"
done
chmod -R u=rwX,go=rX "$games.new"
rm -rf "$games.old"
if [ -e "$games" ]; then mv "$games" "$games.old"; fi
mv "$games.new" "$games"
rm -rf "$games.old"
