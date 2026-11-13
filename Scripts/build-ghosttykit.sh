#!/bin/sh
# Builds GhosttyKit.xcframework (libghostty) for the experimental Ghostty
# terminal and puts it in Frameworks/. Needs zig (brew install zig).
#   Scripts/build-ghosttykit.sh [ghostty-tag]   (default v1.4.0)
set -eu
TAG="${1:-v1.4.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${GHOSTTY_SRC:-$ROOT/.build/ghostty-src}"
if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "$TAG" https://github.com/ghostty-org/ghostty.git "$SRC"
fi
cd "$SRC"
zig build -Demit-macos-app=false -Demit-xcframework=true -Dxcframework-target=native -Doptimize=ReleaseFast
mkdir -p "$ROOT/Frameworks"
rm -rf "$ROOT/Frameworks/GhosttyKit.xcframework"
cp -R macos/GhosttyKit.xcframework "$ROOT/Frameworks/"
echo "GhosttyKit installed. Enable with: defaults write com.kanban-code.app experimentalGhosttyTerminal -bool true"
