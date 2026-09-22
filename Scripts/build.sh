#!/bin/bash
#
# build.sh — Paprika 를 빌드하고 dist/Paprika.app 번들을 만든다.
#
#   ./Scripts/build.sh              릴리스 빌드 + 번들 + ad-hoc 서명
#   ./Scripts/build.sh --debug      디버그 빌드
#
# 이 스크립트는 Apple Silicon 맥에서만 의미가 있다.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONFIGURATION="release"
if [[ "${1:-}" == "--debug" ]]; then
    CONFIGURATION="debug"
fi

VERSION="1.0.0"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

APP_NAME="Paprika"
DIST_DIR="$REPO_ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
# Mach-O 실행 파일은 Resources/ 가 아니라 Helpers/ 에 둔다 (번들 규약).
HELPERS_DIR="$CONTENTS/Helpers"

info()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 사전 확인

[[ "$(uname -s)" == "Darwin" ]] || die "macOS 에서만 빌드할 수 있습니다. (IOKit/SwiftUI 필요)"

if [[ "$(uname -m)" != "arm64" ]]; then
    warn "Apple Silicon(arm64) 이 아닌 것 같습니다. Paprika 는 Apple Silicon 전용입니다."
fi

command -v swift >/dev/null || die "swift 를 찾을 수 없습니다. Xcode 또는 Command Line Tools 를 설치하세요."
command -v codesign >/dev/null || die "codesign 을 찾을 수 없습니다."

SWIFT_VERSION="$(swift --version 2>&1 | head -1)"
info "툴체인: $SWIFT_VERSION"

# ---------------------------------------------------------------- 빌드

info "swift build ($CONFIGURATION)"
swift build -c "$CONFIGURATION"

BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
info "빌드 결과: $BIN_DIR"

for binary in Paprika paprikad paprikactl; do
    [[ -f "$BIN_DIR/$binary" ]] || die "$binary 가 빌드되지 않았습니다."
done

# ---------------------------------------------------------------- 번들 조립

info "Paprika.app 번들 조립"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$HELPERS_DIR"

cp "$BIN_DIR/Paprika" "$MACOS_DIR/Paprika"

# 도우미와 CLI 는 Contents/Helpers 에. 설치 스크립트가 여기서 찾아간다.
cp "$BIN_DIR/paprikad" "$HELPERS_DIR/paprikad"
cp "$BIN_DIR/paprikactl" "$HELPERS_DIR/paprikactl"
cp "$REPO_ROOT/Resources/com.paprika.helperd.plist" "$RESOURCES_DIR/"
cp "$REPO_ROOT/Scripts/install-helper.sh" "$RESOURCES_DIR/"
cp "$REPO_ROOT/Scripts/uninstall.sh" "$RESOURCES_DIR/"
chmod +x "$RESOURCES_DIR/install-helper.sh" "$RESOURCES_DIR/uninstall.sh"

sed -e "s/__VERSION__/$VERSION/" \
    -e "s/__BUILD__/$BUILD_NUMBER/" \
    "$REPO_ROOT/Resources/Info.plist" > "$CONTENTS/Info.plist"

printf 'APPL????' > "$CONTENTS/PkgInfo"

# ---------------------------------------------------------------- 서명
#
# 배포하지 않으므로 ad-hoc 서명(-)으로 충분하다.
# --identifier 를 명시하는 이유: 데몬이 XPC 피어를 코드서명 identifier 로 검증하는데,
# 그 값이 Sources/paprikad/PeerValidator.swift 의 허용 목록과 맞아야 한다.
#
info "ad-hoc 서명"
codesign --force --sign - --timestamp=none \
    --identifier "com.paprika.helperd" "$HELPERS_DIR/paprikad"
codesign --force --sign - --timestamp=none \
    --identifier "paprikactl" "$HELPERS_DIR/paprikactl"
codesign --force --sign - --timestamp=none \
    --identifier "com.paprika.Paprika" "$APP_BUNDLE"

info "서명 확인 (--strict 로 번들 배치까지 검사)"
codesign --verify --strict --verbose=1 "$APP_BUNDLE" 2>&1 | sed 's/^/    /'
codesign -d --verbose=1 "$APP_BUNDLE" 2>&1 | grep -i identifier | sed 's/^/    /' || true

# ---------------------------------------------------------------- 마무리

cat <<EOF

빌드 완료: $APP_BUNDLE

다음 단계
  1) 앱을 원하는 곳에 두세요 (예: /Applications)
         cp -R "$APP_BUNDLE" /Applications/

  2) 권한 도우미를 설치하세요 (한 번만)
         sudo "$REPO_ROOT/Scripts/install-helper.sh"

  3) 앱을 실행하세요
         open /Applications/$APP_NAME.app

  상태 확인:   paprikactl status
  전부 제거:   sudo "$REPO_ROOT/Scripts/uninstall.sh"
EOF
