#!/usr/bin/env bash
set -euo pipefail

private=${1:?usage: update-key.sh <where to write the private key>}
package=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$package/packaging"
umask 077
openssl ecparam -name prime256v1 -genkey -noout -out "$private"
openssl ec -in "$private" -pubout -out "$package/packaging/update-public-key.pem"
echo "Wrote $package/packaging/update-public-key.pem. Store $private as WINDOWS_UPDATE_PRIVATE_KEY in the windows-release environment, then delete it."
