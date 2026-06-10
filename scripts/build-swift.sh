#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:-${OUTPUT:-${ROOT_DIR}/.build/release/xcodecli}}"
BUILD_CHANNEL="${BUILD_CHANNEL:-release}"

SOURCE_VERSION="$(sed -n 's/.*static let source = "\(.*\)"/\1/p' "${ROOT_DIR}/Sources/XcodeCLICore/Shared/Version.swift" | head -n 1)"
SWIFT_FLAGS=()

case "$BUILD_CHANNEL" in
  release)
    ;;
  dev)
    SWIFT_FLAGS=(-Xswiftc -DXCODECLI_FORCE_DEV)
    ;;
  *)
    echo "[build-swift] unsupported BUILD_CHANNEL: ${BUILD_CHANNEL} (expected release or dev)" >&2
    exit 2
    ;;
esac

echo "[build-swift] version: ${SOURCE_VERSION:-v0.0.0}"
echo "[build-swift] channel: ${BUILD_CHANNEL}"
echo "[build-swift] output:  ${OUTPUT}"

cd "$ROOT_DIR"
swift build -c release "${SWIFT_FLAGS[@]}"

# Copy to requested output location if different from default
BUILT_BINARY="${ROOT_DIR}/.build/release/xcodecli"
if [[ "$OUTPUT" != "$BUILT_BINARY" ]]; then
  mkdir -p "$(dirname "$OUTPUT")"
  cp "$BUILT_BINARY" "$OUTPUT"
fi

echo "[build-swift] done"
