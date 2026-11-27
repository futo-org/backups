#!/usr/bin/env bash
set -euo pipefail

version=$1
stage=${2:-all}
out=${OUT_DIR:-build/release}
package=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)

if [ "$stage" = all ] || [ "$stage" = publish ]; then
  for pair in arm64:ARM64 x64:x64; do
    arch=${pair%%:*}
    platform=${pair##*:}
    publish="$out/FUTO-Backups-$version-windows-$arch"
    rm -rf "$publish" "$publish.zip"
    dotnet publish "$package/src/FutoBackups/FutoBackups.csproj" -c Release -r "win-$arch" -p:Platform="$platform" \
      -p:Version="$version" -o "$publish" -nologo
    for helper in restic.exe restic-proxy.exe; do
      test -f "$publish/Helpers/$helper"
    done
  done
fi

if [ "$stage" = all ] || [ "$stage" = package ]; then
  sign=()
  if [ -n "${ARTIFACT_SIGNING_METADATA:-}" ]; then
    sign=(--azureTrustedSignFile "$ARTIFACT_SIGNING_METADATA")
  fi

  notes=()
  if [ -n "${RELEASE_NOTES_FILE:-}" ]; then
    notes=(--releaseNotes "$RELEASE_NOTES_FILE")
  fi

  for arch in arm64 x64; do
    rm -rf "$out/win-$arch"
    DOTNET_ROLL_FORWARD=Major vpk pack --packId FUTOBackups --packVersion "$version" --packTitle "FUTO Backups" --packAuthors FUTO \
      --packDir "$out/FUTO-Backups-$version-windows-$arch" --mainExe FutoBackups.exe \
      --icon "$package/src/FutoBackups/Assets/AppIcon.ico" --runtime "win-$arch" --channel "win-$arch" --delta None \
      --outputDir "$out/win-$arch" "${sign[@]}" "${notes[@]}"
    rm -rf "$out/FUTO-Backups-$version-windows-$arch"
  done
  (cd "$out" && for dir in win-*; do (cd "$dir" && sha256sum FUTOBackups-*); done > SHA256SUMS)
fi
