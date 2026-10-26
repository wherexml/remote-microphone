#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ $# != 1 ]]; then print 'Usage: verify-recovery.sh /private/path/to/pairing-url.txt'; exit 2; fi
mkdir -p build artifacts
swiftc -parse-as-library Shared/Transport.swift Shared/PCMEncoder.swift Shared/AACCodec.swift e2e/Recovery.swift -o build/recovery-e2e > build/recovery-build.log 2>&1
build/recovery-e2e "$1"
