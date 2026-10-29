#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swiftc -parse-as-library \
  "$ROOT/Shared/Transport.swift" \
  "$ROOT/e2e/PhonePairingPresentation.swift" \
  -o "$ROOT/build/PhonePairingPresentationTests"
"$ROOT/build/PhonePairingPresentationTests"
