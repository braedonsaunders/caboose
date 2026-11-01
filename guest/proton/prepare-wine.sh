#!/bin/bash
# Fetches GE-Proton's Wine at a release tag and applies GE's own Wine patches to it, as
# GE's build does (patches/protonprep-valve-staging.sh, its Wine section), into $1/ge.
set -euo pipefail
work=$1 tag=${2:-GE-Proton11-11}
mkdir -p "$work" && cd "$work"
if [ ! -d ge ]; then
  git clone -q --depth 1 --branch "$tag" https://github.com/GloriousEggroll/proton-ge-custom ge
fi
cd ge
if [ -f .caboose-prepared ]; then echo "prepared $(git -C wine log -1 --format=%h)"; exit 0; fi
for module in wine wine-staging; do
  sha=$(git ls-tree HEAD "$module" | awk '{print $3}')
  url=$(git config -f .gitmodules "submodule.$module.url")
  if [ ! -d "$module/.git" ] && [ ! -f "$module/.git" ]; then
    rm -rf "$module"; git init -q "$module"
    git -C "$module" fetch -q --depth 1 "$url" "$sha"
    git -C "$module" checkout -q FETCH_HEAD
  fi
done
# GE's patch script, its helper functions and its Wine section only.
script=patches/protonprep-valve-staging.sh
start=$(grep -n '^### (2) WINE PATCHING ###' "$script" | cut -d: -f1)
{ sed -n '1,/^### (1) PREP SECTION ###/p' "$script" | sed '$d'; sed -n "${start},\$p" "$script"; } > /tmp/wine-prep.sh
bash /tmp/wine-prep.sh
# What GE's Makefile generates after the patches (.wine-post-source).
(cd wine && XDG_CACHE_HOME=/tmp dlls/winevulkan/make_vulkan -x vk.xml -X video.xml && { tools/make_specfiles || true; })
git -C wine add -A >/dev/null && git -C wine -c user.email=b@caboose -c user.name=build commit -qm "GE-Proton patches" >/dev/null
touch .caboose-prepared
echo "prepared $(git -C wine log -1 --format=%h)"
