#!/bin/zsh
# 功能：执行 Friday 仓库的零付费自动质量门禁，统一给出提交前的基础验证信号。
# 职责：校验 plist、pbxproj 和 Node 语法，运行 Backend 假上游测试，并用完整 Xcode 完成 Swift 类型检查和 App 测试。
# 边界：不读取真实 API Key，不申请 Realtime 凭证，也不替代麦克风、Accessibility、屏幕录制和跨应用写回的真机验收。

set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
DERIVED_DATA_DIRECTORY="${FRIDAY_DERIVED_DATA:-/tmp/FridayVerifyDerivedData}"

cd "$PROJECT_DIRECTORY"

plutil -lint Friday/Info.plist
plutil -lint Friday.xcodeproj/project.pbxproj
node --check Backend/server.mjs
node --check Backend/service-manager.mjs
node --check Backend/server.test.mjs

(
  cd Backend
  npm test
)

DEVELOPER_DIRECTORY="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ "$DEVELOPER_DIRECTORY" == "/Library/Developer/CommandLineTools" ]]; then
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    DEVELOPER_DIRECTORY=/Applications/Xcode.app/Contents/Developer
  elif [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
    DEVELOPER_DIRECTORY=/Applications/Xcode-beta.app/Contents/Developer
  else
    print -u2 "Full Xcode is required to run Friday tests."
    exit 1
  fi
fi

DEVELOPER_DIR="$DEVELOPER_DIRECTORY" xcrun swiftc \
  -typecheck \
  Backend/keychain-configure.swift

DEVELOPER_DIR="$DEVELOPER_DIRECTORY" xcrun swiftc \
  -parse-as-library \
  -typecheck \
  scripts/RealtimeTalkProbe.swift

DEVELOPER_DIR="$DEVELOPER_DIRECTORY" xcodebuild test \
  -project Friday.xcodeproj \
  -scheme Friday \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_DIRECTORY" \
  -quiet
