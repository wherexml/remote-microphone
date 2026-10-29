#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/pairing-url-test"
mkdir -p "$ROOT/build"
swiftc -sdk "$(xcrun --show-sdk-path)"   "$ROOT/Shared/Transport.swift"   "$ROOT/e2e/PairingURL.swift"   -o "$OUT"
"$OUT"
