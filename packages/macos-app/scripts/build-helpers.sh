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
if [ -n "$(git -C "$source" for-each-ref "refs/tags/$commit" "refs/heads/$commit" "refs/remotes/origin/$commit")" ]; then
  echo "$commit is a ref name, not a commit id" >&2
  exit 1
fi
full=$(git -C "$source" rev-parse --verify --quiet "$commit^{commit}") || full=
if [ -z "$full" ]; then
  echo "$commit does not resolve to a commit in futo-org/restic" >&2
  exit 1
fi
case "$full" in
  "$commit"*) ;;
  *)
    echo "$commit is not a prefix of $full" >&2
    exit 1
    ;;
esac
git -C "$source" checkout -q "$full"
if [ "$(git -C "$source" rev-parse HEAD)" != "$full" ]; then
  echo "checked out HEAD does not match $full" >&2
  exit 1
fi
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
