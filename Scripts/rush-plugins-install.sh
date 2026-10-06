#!/bin/sh
# Builds Kanban Code's rush plugins (plugins/rush/*) and installs them where
# rush loads plugins from, on this machine or, with an ssh target, on a
# machine that runs cards.
#
#   Scripts/rush-plugins-install.sh                       # this Mac
#   Scripts/rush-plugins-install.sh root@100.114.220.85   # another machine
#
# rush runs an installed plugin only once you approve it, and again after any
# of its files change: at a terminal, the script runs `rush plugin approve`
# for each plugin it changed; otherwise it prints the command to run.
# rush sandboxes installed plugins and so runs them only on macOS; on another
# system the script says so and installs nothing.
set -eu

here="$(cd "$(dirname "$0")/.." && pwd)"
target="${1:-}"

# rush's state folder: RUSH_HOME, else ~/.config/rush, else the older
# ~/.config/agtop, whichever holds a config.
rush_home='if [ -n "${RUSH_HOME:-}" ]; then echo "$RUSH_HOME"; elif [ -f "$HOME/.config/rush/config.json" ]; then echo "$HOME/.config/rush"; elif [ -f "$HOME/.config/agtop/config.json" ]; then echo "$HOME/.config/agtop"; else echo "$HOME/.config/rush"; fi'

if [ -n "$target" ]; then
  goos="$(ssh -o BatchMode=yes "$target" uname -s | tr '[:upper:]' '[:lower:]')"
  goarch="$(ssh -o BatchMode=yes "$target" uname -m)"
  root="$(ssh -o BatchMode=yes "$target" "$rush_home")/plugins"
else
  goos="$(uname -s | tr '[:upper:]' '[:lower:]')"
  goarch="$(uname -m)"
  root="$(sh -c "$rush_home")/plugins"
fi
case "$goarch" in
  x86_64) goarch=amd64 ;;
  aarch64 | arm64) goarch=arm64 ;;
esac
if [ "$goos" != darwin ]; then
  echo "${target:-this machine} runs $goos: rush runs installed plugins only on macOS, where it can sandbox them. Nothing installed."
  exit 0
fi

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
changed=""
for dir in "$here"/plugins/rush/*/; do
  name="$(basename "$dir")"
  mkdir -p "$out/$name"
  # An x86_64 plugin can't start in rush's sandbox on Apple Silicon, which
  # blocks Rosetta: build for the machine's own architecture.
  (cd "$dir" && GOOS="$goos" GOARCH="$goarch" CGO_ENABLED=0 go build -trimpath -o "$out/$name/$name" .)
  cp "$dir/plugin.json" "$out/$name/plugin.json"
  if [ -n "$target" ]; then
    if ssh -o BatchMode=yes "$target" "cmp -s '$root/$name/$name' /dev/stdin" < "$out/$name/$name" &&
      ssh -o BatchMode=yes "$target" "cmp -s '$root/$name/plugin.json' /dev/stdin" < "$out/$name/plugin.json"; then
      echo "$name: unchanged on $target"
      continue
    fi
    ssh -o BatchMode=yes "$target" "mkdir -p '$root/$name'"
    scp -q -o BatchMode=yes "$out/$name/$name" "$out/$name/plugin.json" "$target:$root/$name/"
  else
    if cmp -s "$out/$name/$name" "$root/$name/$name" 2>/dev/null && cmp -s "$out/$name/plugin.json" "$root/$name/plugin.json" 2>/dev/null; then
      echo "$name: unchanged"
      continue
    fi
    mkdir -p "$root/$name"
    cp "$out/$name/$name" "$out/$name/plugin.json" "$root/$name/"
  fi
  echo "$name: installed in ${target:+$target:}$root/$name"
  changed="$changed $name"
done

for name in $changed; do
  if [ -z "$target" ] && [ -t 0 ]; then
    rush plugin approve "$name"
  else
    echo "approve it to run: ${target:+ssh -t $target }rush plugin approve $name"
  fi
done
