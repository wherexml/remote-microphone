#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/WaveformVerify.app/Contents/MacOS
swiftc -parse-as-library Shared/Appearance.swift e2e/Waveform.swift -o build/WaveformVerify.app/Contents/MacOS/WaveformVerify
python3 - <<'PY'
import plistlib,pathlib
pathlib.Path('build/WaveformVerify.app/Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'cc.skylance.remotemic.waveform.verify','CFBundleExecutable':'WaveformVerify','CFBundleName':'Waveform Verify','CFBundlePackageType':'APPL'}))
PY
codesign --force --options runtime --sign "${REMOTE_MIC_SIGN_IDENTITY:--}" build/WaveformVerify.app
