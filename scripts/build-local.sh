#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build artifacts
spec=project.yml
[[ -f project.local.yml ]] && spec=project.local.yml
if [[ "${1:-}" == "--unsigned" ]]; then
  spec=project.yml
  signing=(CODE_SIGNING_ALLOWED=NO)
else
  signing=()
  if [[ ! -f project.local.yml ]]; then
    print '请复制 project.local.example.yml 为 project.local.yml，并填写签名 Team ID 与 Bundle ID。'
    print '仅验证编译可使用：scripts/build-local.sh --unsigned'
    exit 2
  fi
fi
${XCODEGEN:-xcodegen} generate --spec "$spec"
xcodebuild -project RemoteMic.xcodeproj -scheme RemoteMicMac -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS' "${signing[@]}" build > build/mac-build.log 2>&1
xcodebuild -project RemoteMic.xcodeproj -scheme RemoteMicPhone -configuration Debug -derivedDataPath build/PhoneDerivedData -destination 'generic/platform=iOS' "${signing[@]}" build > build/phone-build.log 2>&1
if [[ "${1:-}" != "--unsigned" ]]; then
  codesign --verify --strict build/DerivedData/Build/Products/Debug/RemoteMic.app
  codesign --verify --strict build/PhoneDerivedData/Build/Products/Debug-iphoneos/RemoteMicPhone.app
fi
print '两端构建完成，日志位于 build/mac-build.log 和 build/phone-build.log。'
