#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p 'build/Remote Mic Verify.app/Contents/MacOS'
swiftc -parse-as-library Shared/Transport.swift Mac/AudioOutput.swift e2e/Capture.swift -o 'build/Remote Mic Verify.app/Contents/MacOS/Capture'
swiftc -parse-as-library Shared/Transport.swift Shared/PCMEncoder.swift Shared/AACCodec.swift e2e/Sender.swift -o build/synthetic-sender
python3 - <<'PY'
import plistlib,pathlib
pathlib.Path('build/Remote Mic Verify.app/Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'cc.skylance.remotemic.verify','CFBundleExecutable':'Capture','CFBundleName':'Remote Mic Verify','CFBundlePackageType':'APPL','NSMicrophoneUsageDescription':'仅录制 BlackHole 虚拟输入 20 秒以验证手机音频通路。'}))
pathlib.Path('build/capture.entitlements').write_bytes(plistlib.dumps({'com.apple.security.device.audio-input':True}))
PY
codesign --force --options runtime --sign "${REMOTE_MIC_SIGN_IDENTITY:--}" --entitlements build/capture.entitlements 'build/Remote Mic Verify.app'
