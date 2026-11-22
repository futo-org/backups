#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 1 ] || [ -z "${1:-}" ]; then
  echo "usage: build-helpers.sh <out-dir>" >&2
  exit 1
fi

out=$(mkdir -p "$1" && cd "$1" && pwd)
package=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$package/../.." && pwd)

image=$(sed -n 's/^ARG RESTIC_IMAGE=//p' "$root/packages/standalone-app/Dockerfile")
tag=${image#*:}
tag=${tag%@*}
commit=${tag#sha-}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
source=$work/restic

git clone -q --filter=blob:none --no-checkout https://github.com/futo-org/restic.git "$source"
git -C "$source" checkout -q "$commit"
sed -i.orig -E "s/^const Version = \"([^\"]+)\"$/const Version = \"\1+futo.$commit\"/" "$source/internal/global/global.go"

for arch in arm64 amd64; do
  (cd "$root" && GOOS=darwin GOARCH="$arch" CGO_ENABLED=0 mise exec -- go -C "$source" build \
    -trimpath -ldflags "-s -w" -tags disable_grpc_modules -o "$work/restic-$arch" ./cmd/restic)
  (cd "$root" && GOOS=darwin GOARCH="$arch" CGO_ENABLED=0 mise exec -- go -C "$root/packages/restic-proxy" build \
    -trimpath -ldflags "-s -w" -o "$work/restic-proxy-$arch" .)
done

lipo -create -output "$out/restic" "$work/restic-arm64" "$work/restic-amd64"
lipo -create -output "$out/restic-proxy" "$work/restic-proxy-arm64" "$work/restic-proxy-amd64"
chmod 0755 "$out/restic" "$out/restic-proxy"
