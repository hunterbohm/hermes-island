#!/bin/bash
# Regenerates Resources/AppIcon.icns, Resources/Assets.car and docs/icon.png from the SVGs in Resources/Icon.
# AppIcon-small.svg is the same mark drawn bolder for 16 and 32 px, where the full one blurs. macOS 26 puts an icon
# that comes only as .icns in a gray frame at small sizes, so the app also ships it in an asset catalog. Needs
# rsvg-convert (brew install librsvg), and Xcode's actool for Assets.car; without Xcode the committed one stays.
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
if xcrun --find actool >/dev/null 2>&1; then
    catalog="$scratch/Assets.xcassets/AppIcon.appiconset"
    mkdir -p "$catalog" "$scratch/compiled"
    cp "$iconset"/*.png "$catalog/"
    printf '{"info":{"version":1,"author":"xcode"}}\n' > "$scratch/Assets.xcassets/Contents.json"
    {
        printf '{"info":{"version":1,"author":"xcode"},"images":['
        separator=""
        for size in 16 32 128 256 512; do
            for scale in 1 2; do
                suffix=""; [[ $scale == 2 ]] && suffix="@2x"
                name="icon_${size}x${size}${suffix}.png"
                printf '%s{"idiom":"mac","size":"%sx%s","scale":"%sx","filename":"%s"}' "$separator" "$size" "$size" "$scale" "$name"
                separator=","
            done
        done
        printf ']}\n'
    } > "$catalog/Contents.json"
    xcrun actool "$scratch/Assets.xcassets" --compile "$scratch/compiled" --platform macosx --minimum-deployment-target 26.0 \
        --app-icon AppIcon --output-partial-info-plist "$scratch/partial.plist" >/dev/null
    cp "$scratch/compiled/Assets.car" "$root/Resources/Assets.car"
else
    echo "No actool (Xcode), so Resources/Assets.car is left as it is." >&2
fi
printf 'Wrote Resources/AppIcon.icns (%s bytes), Resources/Assets.car and docs/icon.png.\n' "$(stat -f %z "$root/Resources/AppIcon.icns")"
