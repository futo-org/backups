#!/usr/bin/env bash
set -euo pipefail

package=$(cd "$(dirname "$0")/.." && pwd)
spec=$(cygpath -w "$(mktemp --suffix=.json)" 2>/dev/null || mktemp --suffix=.json)
trap 'rm -f "$spec"' EXIT

node -e '
const fs = require("fs");
const [source, target] = process.argv.slice(1);
const document = JSON.parse(fs.readFileSync(source, "utf8"));
document.paths = Object.fromEntries(Object.entries(document.paths).map(([path, item]) => [path.replace(/^\/api\//, "/"), item]));
fs.writeFileSync(target, JSON.stringify(document, (key, value) => key === "enum" ? undefined : value));
' "$package/../yucca-api-client/openapi-specs.json" "$spec"

nswag run "$package/src/FutoBackups.YuccaApi/nswag.json" "/variables:Spec=$spec"
