#!/usr/bin/env bash
set -euo pipefail

package=$(cd "$(dirname "$0")/.." && pwd)
destination=${INSTALL_DIR:-/Applications}/FUTO\ Backups.app

revision=$(git -C "$package" rev-parse --short HEAD)
if [ -n "$(git -C "$package" status --porcelain -- .)" ]; then
  revision="$revision.dirty"
fi
release=$(git -C "$package" tag --merged HEAD --list 'v*' --sort=-v:refname |
  grep -E -m 1 '^v[0-9]+\.[0-9]+\.[0-9]+$' || true)
if [ -z "$release" ]; then
  echo "no vMAJOR.MINOR.PATCH release tag in HEAD's history; fetch tags (git fetch --tags) and retry" >&2
  exit 1
fi
release=${release#v}
IFS=. read -r major minor patch <<<"$release"
build=$((10#$major * 1000000 + 10#$minor * 1000 + 10#$patch))
version="$release-dev.$revision"

work=$(mktemp -d)
chmod 700 "$work"
keychain="$work/signing.keychain-db"
search_list=()
while IFS= read -r entry; do
  if [ -n "$entry" ]; then search_list+=("$entry"); fi
done < <(security list-keychains -d user | sed -e 's/^ *//' -e 's/"//g')
cleanup() {
  security list-keychains -d user -s "${search_list[@]}"
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

secret() {
  infisical secrets get "$1" --env global --path /ci --plain --silent
}

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  identity=$CODESIGN_IDENTITY
else
  if [ -z "${INFISICAL_PROJECT_ID:-}" ]; then
    echo "set CODESIGN_IDENTITY, or INFISICAL_PROJECT_ID to the apple-signing project" >&2
    exit 1
  fi
  identity=$(secret APPLE_DEVELOPER_ID_APPLICATION__IDENTITY)
  keychain_password=$(openssl rand -hex 24)
  security create-keychain -p "$keychain_password" "$keychain"
  security set-keychain-settings -lut 3600 "$keychain"
  security unlock-keychain -p "$keychain_password" "$keychain"
  secret APPLE_DEVELOPER_ID_APPLICATION__P12_BASE64 | base64 --decode >"$work/certificate.p12"
  security import "$work/certificate.p12" -k "$keychain" \
    -P "$(secret APPLE_DEVELOPER_ID_APPLICATION__P12_PASSWORD)" -T /usr/bin/codesign >/dev/null
  rm -f "$work/certificate.p12"
  security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null
  security list-keychains -d user -s "$keychain" "${search_list[@]}"
fi

app=$(cd "$package" && CODESIGN_IDENTITY="$identity" MAC_APP_VERSION="$version" MAC_APP_BUILD="$build" \
  scripts/bundle.sh | tail -n 1)

if [ "${NOTARIZE:-}" = "1" ]; then
  secret APPLE_NOTARY_API_KEY__P8 >"$work/notary.p8"
  chmod 600 "$work/notary.p8"
  ditto -c -k --keepParent "$app" "$work/notarize.zip"
  xcrun notarytool submit "$work/notarize.zip" --key "$work/notary.p8" \
    --key-id "$(secret APPLE_NOTARY_API_KEY__KEY_ID)" --issuer "$(secret APPLE_NOTARY_API_KEY__ISSUER_ID)" --wait
  xcrun stapler staple "$app"
fi

executable="$destination/Contents/MacOS/FutoBackups"
refuse_if_busy() {
  if pgrep -f "^$destination/Contents/Helpers/" >/dev/null; then
    echo "FUTO Backups is backing up or restoring; let it finish, then run mac:install again" >&2
    exit 1
  fi
}
refuse_if_busy
osascript -e 'quit app id "org.futo.backups.mac"' >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
  pgrep -f -x "$executable" >/dev/null || break
  sleep 0.5
done
if pgrep -f -x "$executable" >/dev/null; then
  refuse_if_busy
  pkill -TERM -f -x "$executable" || true
  for _ in $(seq 1 20); do
    pgrep -f -x "$executable" >/dev/null || break
    sleep 0.5
  done
fi
if pgrep -f -x "$executable" >/dev/null; then
  echo "FUTO Backups is still running; quit it and run mac:install again" >&2
  exit 1
fi
rm -rf "$destination"
ditto "$app" "$destination"
codesign --verify --deep --strict "$destination"
printf 'installed %s (%s)\n' "$destination" "$version"
open "$destination"
