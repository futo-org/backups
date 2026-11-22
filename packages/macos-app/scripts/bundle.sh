#!/usr/bin/env bash
set -euo pipefail

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

package=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$package/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swift build -c release --product FutoBackups --package-path "$package"
bin=$(swift build -c release --show-bin-path --package-path "$package")

(cd "$root" && mise run restic:install)

(cd "$root/packages/restic-proxy" &&
  CGO_ENABLED=0 mise exec -- go build -trimpath -ldflags "-s -w" -o "$work/restic-proxy" .)

app="$package/build/FUTO Backups.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
install -m 0755 "$bin/FutoBackups" "$app/Contents/MacOS/FutoBackups"
install -m 0755 "$root/.mise/bin/restic" "$app/Contents/Helpers/restic"
install -m 0755 "$work/restic-proxy" "$app/Contents/Helpers/restic-proxy"
install -m 0644 "$package/Resources/Info.plist" "$app/Contents/Info.plist"
install -m 0644 "$package/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"

# Nested code must be signed before the bundle or the outer seal no longer matches.
codesign --force --options runtime --timestamp=none --sign - "$app/Contents/Helpers/restic"
codesign --force --options runtime --timestamp=none --sign - "$app/Contents/Helpers/restic-proxy"
codesign --force --options runtime --timestamp=none --sign - "$app"

codesign --verify --deep --strict --verbose=2 "$app"
printf '%s\n' "$app"
