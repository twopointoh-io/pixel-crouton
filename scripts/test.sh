#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
build="$(mktemp -d "${TMPDIR:-/tmp}/pixel-crouton-test.XXXXXX")"
trap 'rm -rf -- "$build"' EXIT
xcrun swiftc -swift-version 6 -O Sources/ImagePipeline.swift Tests/PipelineTests.swift -o "$build/PipelineTests"
"$build/PipelineTests" "$@"
