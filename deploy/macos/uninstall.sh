#!/usr/bin/env bash
# Remove the per-user programs and agents; keep computers unless explicitly purged.
set -euo pipefail
purge=0
yes=0
stage_home=
while [[ $# -gt 0 ]]; do
  case $1 in
    --purge) purge=1; shift ;;
    --yes) yes=1; shift ;;
    --stage-home) stage_home=${2:?}; shift 2 ;;
    -h|--help) echo 'Usage: uninstall.sh [--purge] [--yes]'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ $(uname -s) == Darwin && $(id -u) != 0 ]] || { echo 'Run as your macOS login user, without sudo' >&2; exit 1; }
install_home=$HOME
if [[ -n $stage_home ]]; then
  [[ $stage_home == /* && $stage_home != / && $stage_home != "$HOME" ]] || { echo 'Use a separate absolute staging directory' >&2; exit 1; }
  install_home=$stage_home
fi
root=$install_home/Library/Application\ Support/Caboose
agents=$install_home/Library/LaunchAgents
if [[ $purge == 1 && $yes == 0 ]]; then
  printf 'Delete every Caboose computer, account and setting? Type "delete" to confirm: '
  read -r answer </dev/tty
  [[ $answer == delete ]] || { echo 'Nothing removed.'; exit 0; }
fi
for service in com.caboose.menu com.caboose.host; do
  if [[ -z $stage_home ]] && launchctl print "gui/$(id -u)/$service" >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/$service"
    for ((attempt=0; attempt<180; attempt++)); do
      if ! launchctl print "gui/$(id -u)/$service" >/dev/null 2>&1; then break; fi
      sleep 1
    done
    if launchctl print "gui/$(id -u)/$service" >/dev/null 2>&1; then
      echo "Timed out stopping $service; programs and computer data retained" >&2
      exit 1
    fi
  fi
  rm -f "$agents/$service.plist"
done
# Never remove an unrelated app someone placed in Applications.
app=$install_home/Applications/Caboose.app
if [[ -L $app ]]; then
  case $(readlink "$app") in "$root"/versions/*/Caboose.app) rm "$app" ;; esac
fi
rm -f "$root/current"
rm -rf "$root/versions"
if [[ $purge == 1 ]]; then
  rm -rf "$root"
  echo 'Removed Caboose and all of its computers, accounts and settings.'
else
  echo "Removed Caboose. Kept computers, accounts and settings in $root. Reinstall to use them again."
fi
