#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ $# != 1 ]]; then print 'Usage: verify-loopback.sh /private/path/to/pairing-url.txt'; exit 2; fi
# Start the installed receiver first; stop the phone. Never log the pairing URL.
scripts/build-verifier.sh > build/verifier-build.log 2>&1
'build/Remote Mic Verify.app/Contents/MacOS/Capture' > build/capture.log 2>&1 &
capture_pid=$!
sleep 1
build/synthetic-sender "$1"
wait "$capture_pid"
python3 scripts/check-loopback.py
