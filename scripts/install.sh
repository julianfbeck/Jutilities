#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
source_app="$project_root/build/DerivedData/Build/Products/Release/Jutilities.app"
destination="${1:-$HOME/Applications}"

if [[ $# -gt 1 ]]; then
    printf 'Usage: %s [applications-directory]\n' "$0" >&2
    exit 1
fi
if [[ ! -x "$source_app/Contents/MacOS/Jutilities" ]]; then
    printf 'Build Jutilities first with ./scripts/build.sh.\n' >&2
    exit 1
fi
if /usr/bin/pgrep -x Jutilities >/dev/null; then
    printf 'Quit Jutilities before replacing the installed app.\n' >&2
    exit 1
fi
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")"
if [[ "$bundle_id" != 'sh.juli.Jutilities' ]]; then
    printf 'The build has an unexpected bundle identity.\n' >&2
    exit 1
fi
/usr/bin/codesign --verify --deep --strict "$source_app"
/bin/mkdir -p "$destination"
destination="$(cd "$destination" && pwd)"
installed_app="$destination/Jutilities.app"
if [[ -L "$installed_app" ]]; then
    printf 'Refusing to replace a symbolic-link install.\n' >&2
    exit 1
fi
stage_directory="$(/usr/bin/mktemp -d "$destination/.Jutilities-install.XXXXXX")"
trap '/bin/rm -rf "$stage_directory"' EXIT
/usr/bin/ditto "$source_app" "$stage_directory/Jutilities.app"
/usr/bin/codesign --verify --deep --strict "$stage_directory/Jutilities.app"

previous_app=""
if [[ -e "$installed_app" ]]; then
    backup_directory="$destination/.Jutilities-backups"
    /bin/mkdir -p "$backup_directory"
    previous_app="$backup_directory/Jutilities-$(/bin/date -u +%Y%m%dT%H%M%SZ)-$$.app"
    /bin/mv "$installed_app" "$previous_app"
fi
if ! /bin/mv "$stage_directory/Jutilities.app" "$installed_app"; then
    if [[ -n "$previous_app" && ! -e "$installed_app" ]]; then
        /bin/mv "$previous_app" "$installed_app"
    fi
    printf 'Installation failed; the previous app was restored when possible.\n' >&2
    exit 1
fi
printf 'Installed: %s\n' "$installed_app"
if [[ -n "$previous_app" ]]; then
    printf 'Previous app retained: %s\n' "$previous_app"
fi
printf 'Clipboard history and preferences were preserved.\n'
