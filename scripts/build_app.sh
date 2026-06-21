#!/bin/bash
#
# ClaudeMonitor 빌드 + .app 번들 조립(+위젯) + 서명 + 로컬 설치 스크립트
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# 공유 조립 헬퍼 (assemble_app, APP_NAME/BINARY 등)
source "$ROOT/scripts/_assemble.sh"

VERSION="0.1.4"
DIST_DIR="$ROOT/dist"
APP_DIR="$DIST_DIR/${APP_NAME}.app"

echo "==> swift build (release)"
swift build -c release

assemble_app "$APP_DIR" "$VERSION"

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
