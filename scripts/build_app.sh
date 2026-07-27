#!/bin/bash
#
# ClaudeMonitor 빌드 + .app 번들 조립 + ad-hoc 서명 + 로컬 설치 스크립트
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="ClaudeMonitor"
BINARY="ClaudeMonitor"
BUNDLE_ID="com.kimsoungryoul.ClaudeMonitor"
# 버전: 인자 > 최신 git 태그 > 폴백. (상수로 박아두면 릴리즈마다 낡아 UpdateChecker 가 오판한다)
VERSION="${1:-$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"
VERSION="${VERSION:-0.0.0}"

BUILD_DIR="$ROOT/.build/release"
DIST_DIR="$ROOT/dist"
APP_DIR="$DIST_DIR/${APP_NAME}.app"

echo "==> swift build (release)"
swift build -c release

echo "==> assembling ${APP_NAME}.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$BINARY" "$APP_DIR/Contents/MacOS/$BINARY"
chmod +x "$APP_DIR/Contents/MacOS/$BINARY"

# 앱 아이콘(icns) + 헤더용 브랜드 PNG (Bundle.main 으로 로드)
cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$ROOT/Sources/ClaudeMonitor/Resources/AppIconImage.png" "$APP_DIR/Contents/Resources/AppIconImage.png"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>     <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>      <string>${BINARY}</string>
    <key>CFBundleIdentifier</key>      <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>         <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSHumanReadableCopyright</key><string>Multi-account Claude usage monitor</string>
</dict>
</plist>
PLIST

# PkgInfo
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

# 서명 정체성. 기본은 ad-hoc("-") 이고, 그러면 빌드마다 cdhash 가 달라져 키체인 항목의 ACL 과
# 어긋나므로 재설치할 때마다 "접근 허용" 을 한 번 눌러야 한다.
# CODESIGN_IDENTITY 에 고정 인증서(자체 서명 또는 Developer ID)를 주면 그 프롬프트가 사라진다.
#   security find-identity -v -p codesigning        # 사용 가능한 정체성 확인
#   CODESIGN_IDENTITY="ClaudeMonitor Self-Signed" ./scripts/build_app.sh
IDENTITY="${CODESIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
  echo "==> ad-hoc code signing (재설치 시 키체인 접근 허용 1회 필요)"
else
  echo "==> code signing with identity: $IDENTITY"
fi
codesign --force --deep --sign "$IDENTITY" "$APP_DIR"
codesign --verify --verbose=2 "$APP_DIR" || true

echo "==> installing to /Applications"
INSTALL_DIR="/Applications/${APP_NAME}.app"
# 실행 중이면 종료
pkill -f "$APP_DIR/Contents/MacOS/$BINARY" 2>/dev/null || true
pkill -f "$INSTALL_DIR/Contents/MacOS/$BINARY" 2>/dev/null || true
rm -rf "$INSTALL_DIR"
cp -R "$APP_DIR" "$INSTALL_DIR"

echo "==> done"
echo "    번들: $APP_DIR"
echo "    설치: $INSTALL_DIR"
