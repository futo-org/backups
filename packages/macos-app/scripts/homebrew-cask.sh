#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: homebrew-cask.sh <version> <sha256>" >&2
  exit 1
fi
version=$1
sha256=$2

if ! [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "version must be MAJOR.MINOR.PATCH" >&2
  exit 1
fi
if ! [[ $sha256 =~ ^[0-9a-f]{64}$ ]]; then
  echo "sha256 must be 64 lowercase hex characters" >&2
  exit 1
fi

template="$(cd "$(dirname "$0")/.." && pwd)/packaging/homebrew/futo-backups.rb.template"
sed -e "s/@VERSION@/$version/" -e "s/@SHA256@/$sha256/" "$template"
