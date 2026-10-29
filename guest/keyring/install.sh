#!/bin/sh
set -eu
install -Dm755 "$(dirname "$0")/caboose-keyring" /opt/caboose/keyring/caboose-keyring
