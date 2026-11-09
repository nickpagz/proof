#!/bin/bash
# Builds the update-manifest signing tool on first use (and whenever its sources change), then
# runs it. Usage: Scripts/sign-manifest.sh keygen|pubkey|sign|verify …  (no arguments prints help)
# The tool is compiled from Scripts/sign-manifest.swift plus the app's own UpdateManifest.swift,
# so what it signs is exactly what the app verifies.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/build/tools/sign-manifest"
SOURCES=(
    "$ROOT/Scripts/sign-manifest.swift"
    "$ROOT/Sources/Proof/Update/UpdateManifest.swift"
    "$ROOT/Sources/Proof/Update/UpdateError.swift"
)
build=0
if [[ ! -x "$TOOL" ]]; then build=1; fi
for source in "${SOURCES[@]}"; do
    if [[ "$source" -nt "$TOOL" ]]; then build=1; fi
done
if (( build )); then
    mkdir -p "$(dirname "$TOOL")"
    swiftc -O -module-name SignManifest -o "$TOOL" "${SOURCES[@]}"
fi
exec "$TOOL" "$@"
