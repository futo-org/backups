#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 1 ] || [ -z "${1:-}" ]; then
  echo "usage: release.sh <version>" >&2
  exit 1
fi
version=$1

if ! [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "version must be MAJOR.MINOR.PATCH" >&2
  exit 1
fi
IFS=. read -r major minor patch <<< "$version"
if [ "$((10#$minor))" -ge 1000 ] || [ "$((10#$patch))" -ge 1000 ]; then
  echo "minor and patch must be less than 1000" >&2
  exit 1
fi
build=$((10#$major * 1000000 + 10#$minor * 1000 + 10#$patch))

package=$(cd "$(dirname "$0")/.." && pwd)

if [ -z "${SPARKLE_PRIVATE_KEY:-}" ]; then
  echo "SPARKLE_PRIVATE_KEY is required" >&2
  exit 1
fi
if [ -z "${DOWNLOAD_URL_PREFIX:-}" ]; then
  echo "DOWNLOAD_URL_PREFIX is required" >&2
  exit 1
fi
if ! [[ $DOWNLOAD_URL_PREFIX =~ ^https?://[A-Za-z0-9._~:/%-]+/$ ]]; then
  echo "DOWNLOAD_URL_PREFIX must be an http(s) URL ending with / containing only URL-safe characters" >&2
  exit 1
fi

description=""
notes_html=${RELEASE_NOTES_HTML_FILE:-}
if [ -n "$notes_html" ]; then
  if [ ! -f "$notes_html" ]; then
    echo "RELEASE_NOTES_HTML_FILE not found: $notes_html" >&2
    exit 1
  fi
  notes=$(cat "$notes_html")
  case $notes in
    *']]>'*)
      echo "release notes must not contain ]]>" >&2
      exit 1
      ;;
  esac
  description=$(printf '\n      <description><![CDATA[%s]]></description>' "$notes")
fi

notary_set=0
for name in NOTARY_KEY_PATH NOTARY_KEY_ID NOTARY_ISSUER; do
  if [ -n "${!name:-}" ]; then
    notary_set=$((notary_set + 1))
  fi
done
if [ "$notary_set" -ne 0 ] && [ "$notary_set" -ne 3 ]; then
  echo "NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER must all be set or all be unset" >&2
  exit 1
fi

pinned_key=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$package/Resources/Info.plist")
derived_key=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | swift "$package/scripts/sparkle-key.swift" public)
if [ "$derived_key" != "$pinned_key" ]; then
  echo "SPARKLE_PRIVATE_KEY does not match SUPublicEDKey in Resources/Info.plist" >&2
  exit 1
fi

out_dir=${OUT_DIR:-build/release}
case "$out_dir" in
  /*) ;;
  *) out_dir="$package/$out_dir" ;;
esac
mkdir -p "$out_dir"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

"$package/scripts/build-helpers.sh" "$work/helpers"

app=$(cd "$package" && UNIVERSAL=1 SERVER_SELECTION=false HELPERS_DIR="$work/helpers" MAC_APP_VERSION="$version" MAC_APP_BUILD="$build" scripts/bundle.sh |
  tee /dev/stderr | tail -n 1)

if [ "$notary_set" -eq 3 ]; then
  ditto -c -k --keepParent "$app" "$work/notarize.zip"
  xcrun notarytool submit "$work/notarize.zip" \
    --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=2 "$app"
else
  echo "notary vars unset: skipping notarization"
fi

if [ -n "${EXPECTED_TEAM_ID:-}" ]; then
  team=$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  if [ "$team" != "$EXPECTED_TEAM_ID" ]; then
    echo "signed by team '$team', expected $EXPECTED_TEAM_ID" >&2
    exit 1
  fi
fi

zip="$out_dir/FUTO-Backups-$version.zip"
ditto -c -k --keepParent "$app" "$zip"

sign_update=$(find "$package/.build/artifacts" -type f -path '*/bin/sign_update' | head -n 1)
if [ -z "$sign_update" ]; then
  echo "sign_update not found under $package/.build/artifacts" >&2
  exit 1
fi
signed=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sign_update" --ed-key-file - "$zip")
sig=$(printf '%s' "$signed" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
length=$(printf '%s' "$signed" | sed -n 's/.*length="\([0-9]*\)".*/\1/p')
if [ -z "$sig" ] || [ -z "$length" ]; then
  echo "could not read sparkle:edSignature and length from sign_update output" >&2
  exit 1
fi

bundled_key=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$app/Contents/Info.plist") || {
  echo "SUPublicEDKey missing from $app/Contents/Info.plist" >&2
  exit 1
}
swift "$package/scripts/sparkle-key.swift" verify "$zip" "$sig" "$bundled_key"

pub_date=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
appcast="$out_dir/appcast.xml"
cat >"$appcast" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>FUTO Backups</title>
    <item>
      <title>Version $version</title>$description
      <pubDate>$pub_date</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <enclosure url="${DOWNLOAD_URL_PREFIX}FUTO-Backups-$version.zip" length="$length" type="application/octet-stream" sparkle:edSignature="$sig"/>
    </item>
  </channel>
</rss>
EOF

if ! xmllint --noout "$appcast"; then
  echo "appcast is not well-formed XML" >&2
  exit 1
fi

printf 'zip: %s\n' "$zip"
printf 'appcast: %s\n' "$appcast"
