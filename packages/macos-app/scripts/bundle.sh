#!/usr/bin/env bash
set -euo pipefail

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

package=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$package/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ "${UNIVERSAL:-}" = "1" ]; then
  swift build -c release --arch arm64 --arch x86_64 --product FutoBackups --package-path "$package"
  bin=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path --package-path "$package")
else
  swift build -c release --product FutoBackups --package-path "$package"
  bin=$(swift build -c release --show-bin-path --package-path "$package")
fi

if [ -n "${HELPERS_DIR:-}" ]; then
  restic_bin="$HELPERS_DIR/restic"
  proxy_bin="$HELPERS_DIR/restic-proxy"
else
  (cd "$root" && mise run restic:install)
  (cd "$root/packages/restic-proxy" &&
    CGO_ENABLED=0 mise exec -- go build -trimpath -ldflags "-s -w" -o "$work/restic-proxy" .)
  restic_bin="$root/.mise/bin/restic"
  proxy_bin="$work/restic-proxy"
fi

app="$package/build/FUTO Backups.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Frameworks" "$app/Contents/Resources"
install -m 0755 "$bin/FutoBackups" "$app/Contents/MacOS/FutoBackups"
install -m 0755 "$restic_bin" "$app/Contents/Helpers/restic"
install -m 0755 "$proxy_bin" "$app/Contents/Helpers/restic-proxy"
install -m 0644 "$package/Resources/Info.plist" "$app/Contents/Info.plist"
install -m 0644 "$package/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
install -m 0644 "$package/Resources/Wordmark.png" "$package/Resources/Wordmark-dark.png" "$app/Contents/Resources/"

plist="$app/Contents/Info.plist"
version="${MAC_APP_VERSION:-0.0.0}"
build="${MAC_APP_BUILD:-0}"
feed_url="${SPARKLE_FEED_URL:-https://github.com/futo-org/backups/releases/download/macos-appcast/appcast.xml}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$plist"
if /usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$plist" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Set :SUFeedURL $feed_url" "$plist"
else
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $feed_url" "$plist"
fi
if [ -n "${SPARKLE_AUTOMATIC_CHECKS:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks $SPARKLE_AUTOMATIC_CHECKS" "$plist"
fi

ditto "$bin/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"

identity="${CODESIGN_IDENTITY:--}"
if [ "$identity" = "-" ]; then
  timestamp=(--timestamp=none)
else
  timestamp=(--timestamp)
fi
framework="$app/Contents/Frameworks/Sparkle.framework"

codesign --force --options runtime "${timestamp[@]}" --sign "$identity" \
  "$framework/Versions/B/XPCServices/Installer.xpc"
codesign --force --options runtime "${timestamp[@]}" --preserve-metadata=entitlements --sign "$identity" \
  "$framework/Versions/B/XPCServices/Downloader.xpc"
codesign --force --options runtime "${timestamp[@]}" --sign "$identity" \
  "$framework/Versions/B/Autoupdate"
codesign --force --options runtime "${timestamp[@]}" --sign "$identity" \
  "$framework/Versions/B/Updater.app"
codesign --force --options runtime "${timestamp[@]}" --sign "$identity" \
  "$framework"

# Nested code must be signed before the bundle or the outer seal no longer matches.
codesign --force --options runtime "${timestamp[@]}" --sign "$identity" "$app/Contents/Helpers/restic"
codesign --force --options runtime "${timestamp[@]}" --sign "$identity" "$app/Contents/Helpers/restic-proxy"
if [ "$identity" = "-" ]; then
  codesign --force --options runtime "${timestamp[@]}" --entitlements "$package/Resources/AdHoc.entitlements" \
    --sign "$identity" "$app"
else
  codesign --force --options runtime "${timestamp[@]}" --sign "$identity" "$app"
fi

codesign --verify --deep --strict --verbose=2 "$app"
printf '%s\n' "$app"
