#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="Release"
derived_data="$project_root/build/DerivedData"
app_path="$derived_data/Build/Products/$configuration/Jutilities.app"

for tool in xcodegen xcodebuildmcp; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'Missing %s. See README.md for build dependencies.\n' "$tool" >&2
        exit 1
    fi
done

cd "$project_root"
xcodegen generate --spec project.yml
xcodebuildmcp macos build \
    --project-path "$project_root/Jutilities.xcodeproj" \
    --scheme Jutilities \
    --configuration "$configuration" \
    --derived-data-path "$derived_data"

if [[ ! -x "$app_path/Contents/MacOS/Jutilities" ]]; then
    printf 'The build did not produce Jutilities.app.\n' >&2
    exit 1
fi
/usr/bin/codesign --verify --deep --strict "$app_path"
"$app_path/Contents/MacOS/Jutilities" --version
printf 'Built: %s\n' "$app_path"
