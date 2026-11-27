#!/usr/bin/env bash
set -uo pipefail

package=$(cd "$(dirname "$0")/.." && pwd)
for project in "$package"/src/*/*.csproj "$package"/tests/*/*.csproj; do
  dotnet format "$project" > /dev/null
done
exit 0
