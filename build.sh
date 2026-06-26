#!/usr/bin/env bash
# Build pixel-normal-generator.aseprite-extension (POSIX / Git Bash).
# An .aseprite-extension is a .zip with package.json + the .lua files at the
# archive ROOT. Run from the repo root:  ./build.sh
set -euo pipefail

cd "$(dirname "$0")"
name="pixel-normal-generator"
files=(package.json main.lua normalmap.lua ui.lua LICENSE README.md)

for f in "${files[@]}"; do
  [ -f "$f" ] || { echo "Missing file: $f" >&2; exit 1; }
done

mkdir -p dist
rm -f "dist/${name}.aseprite-extension"
# -j keeps the files at the zip root (no directory entries)
zip -j "dist/${name}.aseprite-extension" "${files[@]}"

echo "Built dist/${name}.aseprite-extension"
echo "Install: Aseprite -> Edit -> Preferences -> Extensions -> Add Extension"
