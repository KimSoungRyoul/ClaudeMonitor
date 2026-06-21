#!/bin/bash
#
# 공유 헬퍼: ClaudeMonitor.app 번들 조립(+ 위젯 .appex 임베드) + 코드 서명.
# build_app.sh / package.sh 가 source 해서 assemble_app 함수를 호출한다.
#
# 환경변수:
#   CODESIGN_IDENTITY   서명 ID (기본 "-" = ad-hoc)
#   DEVELOPMENT_TEAM    선택. 설정 시 Info.plist 에 팀 정보를 남긴다(참고용).
#
# 메모: 위젯이 메인 앱의 실시간 데이터를 읽으려면 App Group 컨테이너가 필요하고,
#       이는 호스트 앱과 위젯이 동일한 app-groups 엔타이틀먼트로 "유효하게" 서명돼야 동작한다.
#       ad-hoc(-) 서명에서는 위젯이 .app 에 임베드되긴 하지만 App Group 이 활성화되지 않아
#       위젯에 데이터가 표시되지 않을 수 있다. Developer ID 등으로 서명하면 정상 동작한다.
#       (메뉴바 앱 본체는 비샌드박스라 ad-hoc 에서도 정상 동작한다.)

APP_NAME="ClaudeMonitor"
BINARY="ClaudeMonitor"
WIDGET_BIN="ClaudeMonitorWidget"
BUNDLE_ID="com.kimsoungryoul.ClaudeMonitor"
WIDGET_ID="${BUNDLE_ID}.Widget"
APP_GROUP="group.com.kimsoungryoul.ClaudeMonitor"   # SharedConstants.appGroupId 과 일치해야 함

# 사용: assemble_app <APP_DIR> <VERSION>
assemble_app() {
    local APP_DIR="$1"
    local VERSION="$2"
    local ROOT BUILD_DIR
    ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    BUILD_DIR="$ROOT/.build/release"
    local SIGN_ID="${CODESIGN_IDENTITY:--}"

    echo "==> assembling ${APP_NAME}.app (v${VERSION})"
    rm -rf "$APP_DIR"
    mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

    cp "$BUILD_DIR/$BINARY" "$APP_DIR/Contents/MacOS/$BINARY"
    chmod +x "$APP_DIR/Contents/MacOS/$BINARY"
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
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST

    printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

    # --- 위젯 확장(.appex) 조립 ---
    local WIDGET_SRC="$BUILD_DIR/$WIDGET_BIN"
    if [[ -f "$WIDGET_SRC" ]]; then
        echo "==> embedding ${WIDGET_BIN}.appex"
        local APPEX="$APP_DIR/Contents/PlugIns/${WIDGET_BIN}.appex"
        mkdir -p "$APPEX/Contents/MacOS"
        cp "$WIDGET_SRC" "$APPEX/Contents/MacOS/$WIDGET_BIN"
        chmod +x "$APPEX/Contents/MacOS/$WIDGET_BIN"
        cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>${WIDGET_BIN}</string>
    <key>CFBundleDisplayName</key>     <string>Claude Usage</string>
    <key>CFBundleExecutable</key>      <string>${WIDGET_BIN}</string>
    <key>CFBundleIdentifier</key>      <string>${WIDGET_ID}</string>
    <key>CFBundleVersion</key>         <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundlePackageType</key>     <string>XPC!</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.widgetkit-extension</string>
    </dict>
</dict>
</plist>
PLIST
        printf 'XPC!????' > "$APPEX/Contents/PkgInfo"

        # 위젯 엔타이틀먼트(app-groups) 작성 + 서명
        local WENT
        WENT="$(mktemp -t cm-widget-ent).plist"
        cat > "$WENT" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array><string>${APP_GROUP}</string></array>
</dict>
</plist>
ENT
        codesign --force --sign "$SIGN_ID" --entitlements "$WENT" "$APPEX"
        rm -f "$WENT"
    else
        echo "!! 위젯 바이너리($WIDGET_SRC)가 없어 위젯 임베드를 건너뜁니다. (swift build -c release 먼저 실행)"
    fi

    # --- 호스트 앱 엔타이틀먼트 + 서명 (안쪽 .appex 를 먼저 서명한 뒤 바깥을 서명) ---
    local HENT
    HENT="$(mktemp -t cm-host-ent).plist"
    cat > "$HENT" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array><string>${APP_GROUP}</string></array>
</dict>
</plist>
ENT
    echo "==> code signing (identity: ${SIGN_ID})"
    codesign --force --sign "$SIGN_ID" --entitlements "$HENT" "$APP_DIR"
    rm -f "$HENT"
    codesign --verify --verbose=2 "$APP_DIR" || true
}
