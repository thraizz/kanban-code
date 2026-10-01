#!/bin/sh
# Builds rush for Linux x86_64 at the commit this Mac runs and installs it on
# a machine that runs cards, when the machine's rush differs from this one.
#
#   Scripts/rush-to-machine.sh root@100.114.220.85
#
# The source is a clone of github.com/0xdeafcafe/rush kept in
# ~/.kanban-code/rush-src, checked out at the commit `rush --version` names
# here; RUSH_SRC names another checkout to build as it is. RUSH_ARCH is the
# machine's architecture (default amd64). The binary goes to
# /usr/local/bin/rush. /usr/local/bin/agtop, when the machine has one, is left
# for the hosts it started: they keep running on it until they end.
set -eu

target="${1:?usage: Scripts/rush-to-machine.sh <ssh target>}"
arch="${RUSH_ARCH:-amd64}"

here="$(rush --version 2>/dev/null || echo none)"
there="$(ssh -o BatchMode=yes "$target" 'PATH="$PATH:/usr/local/bin"; rush --version 2>/dev/null || echo none')"
echo "this machine: $here"
echo "$target: $there"
# The date after the commit is each machine's local day, so only the commit counts.
if [ "$(echo "$here" | awk '{print $2}')" = "$(echo "$there" | awk '{print $2}')" ] && [ "${FORCE:-0}" != 1 ]; then
  echo "Same rush, nothing to do (FORCE=1 to install anyway)."
  exit 0
fi

if [ -n "${RUSH_SRC:-}" ]; then
  src="$RUSH_SRC"
else
  src="$HOME/.kanban-code/rush-src"
  if [ ! -d "$src/.git" ]; then
    git clone -q https://github.com/0xdeafcafe/rush "$src"
  fi
  git -C "$src" fetch -q origin
  commit="$(echo "$here" | awk '{print $2}')"
  case "$commit" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) git -C "$src" checkout -q --detach "$commit" ;;
    *) echo "rush here names no commit ($here), building origin/main"; git -C "$src" checkout -q --detach origin/main ;;
  esac
fi

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
(cd "$src" && GOOS=linux GOARCH="$arch" CGO_ENABLED=0 go build -o "$out/rush" ./cmd/rush)
scp -q -o BatchMode=yes "$out/rush" "$target:/usr/local/bin/rush.new"
ssh -o BatchMode=yes "$target" 'chmod 755 /usr/local/bin/rush.new && mv -f /usr/local/bin/rush.new /usr/local/bin/rush && /usr/local/bin/rush --version'
