#!/bin/bash
#
# ClaudeMonitor 패키징 스크립트 (CI/릴리즈용)
# swift build -c release → .app 번들 조립(+위젯) → 서명 → DMG(hdiutil). 로컬 설치는 하지 않음.
# 사용: ./scripts/package.sh [VERSION]   (기본 0.1.4; CI는 태그에서 추출해 전달)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# 공유 조립 헬퍼 (assemble_app, APP_NAME 등)
source "$ROOT/scripts/_assemble.sh"

VERSION="${1:-0.1.4}"
DIST_DIR="$ROOT/dist"
APP_DIR="$DIST_DIR/${APP_NAME}.app"
DMG_PATH="$DIST_DIR/${APP_NAME}-v${VERSION}.dmg"

echo "==> swift build (release)"
swift build -c release

assemble_app "$APP_DIR" "$VERSION"

echo "==> creating DMG via hdiutil"
rm -f "$DMG_PATH"
STAGING="$(mktemp -d)"
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$STAGING"

echo "==> done"
echo "    APP: $APP_DIR"
echo "    DMG: $DMG_PATH"
ls -lh "$DMG_PATH"
