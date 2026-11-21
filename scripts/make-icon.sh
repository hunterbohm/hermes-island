#!/bin/bash
# Regenerates Resources/AppIcon.icns and docs/icon.png from the SVGs in Resources/Icon. AppIcon-small.svg is the
# same mark drawn bolder for 16 and 32 px, where the full one blurs. Needs rsvg-convert (brew install librsvg).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
full="$root/Resources/Icon/AppIcon.svg"
small="$root/Resources/Icon/AppIcon-small.svg"
command -v rsvg-convert >/dev/null || { echo "Install rsvg-convert first: brew install librsvg" >&2; exit 1; }
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
iconset="$scratch/AppIcon.iconset"
mkdir "$iconset"
render() { rsvg-convert -w "$2" -h "$2" "$1" -o "$3"; }
render "$small" 16 "$iconset/icon_16x16.png"
render "$small" 32 "$iconset/icon_16x16@2x.png"
render "$small" 32 "$iconset/icon_32x32.png"
render "$full" 64 "$iconset/icon_32x32@2x.png"
for size in 128 256 512; do
    render "$full" "$size" "$iconset/icon_${size}x${size}.png"
    render "$full" "$((size * 2))" "$iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$iconset" -o "$root/Resources/AppIcon.icns"
render "$full" 256 "$root/docs/icon.png"
printf 'Wrote Resources/AppIcon.icns (%s bytes) and docs/icon.png.\n' "$(stat -f %z "$root/Resources/AppIcon.icns")"
