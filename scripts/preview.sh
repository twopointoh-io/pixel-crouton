#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
build="$(mktemp -d "${TMPDIR:-/tmp}/pixel-crouton-preview.XXXXXX")"
trap 'rm -rf -- "$build"' EXIT
xcrun swiftc -swift-version 6 -O -D DOCS_PREVIEW Sources/*.swift scripts/RenderPreview.swift -o "$build/RenderPreview"
"$build/RenderPreview" "$PWD/docs/preview.png" "$@"
