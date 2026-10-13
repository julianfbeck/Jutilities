#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
iconset="$project_root/build/AppIcon.iconset"

if ! command -v rsvg-convert >/dev/null 2>&1; then
    printf 'Install librsvg to regenerate the icon: brew install librsvg\n' >&2
    exit 1
fi
/bin/mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    for scale in 1 2; do
        pixels=$((size * scale))
        suffix=""
        if [[ "$scale" -eq 2 ]]; then suffix="@2x"; fi
        rsvg-convert --width "$pixels" --height "$pixels" --keep-aspect-ratio \
            --output "$iconset/icon_${size}x${size}${suffix}.png" \
            "$project_root/Config/AppIcon.svg"
    done
done
/usr/bin/iconutil --convert icns --output "$project_root/Config/AppIcon.icns" "$iconset"
printf 'Generated Config/AppIcon.icns from Config/AppIcon.svg.\n'
