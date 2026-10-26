#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build artifacts
swiftc Shared/Transport.swift e2e/main.swift -o build/transport-e2e
build/transport-e2e artifacts/transport.json
