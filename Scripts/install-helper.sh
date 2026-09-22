#!/bin/bash
#
# install-helper.sh — paprikad 를 root LaunchDaemon 으로 설치한다.
#
#   sudo ./Scripts/install-helper.sh
#   sudo ./Scripts/install-helper.sh --allow-unsigned   # 서명 검증 끄기(디버깅용)
#
# 왜 sudo 가 필요한가:
#   충전 제어는 SMC 에 값을 쓰는 일이고, SMC 쓰기는 root 권한이 필요하다.
#   메뉴바 앱은 root 로 돌지 않고, 이 작은 도우미에게 XPC 로 부탁만 한다.
#
set -euo pipefail

LABEL="com.paprika.helperd"
# /usr/local 이 아니라 /Library/PrivilegedHelperTools 에 설치한다.
# Homebrew 가 설치된 맥에서는 /usr/local 이 root:admin 775 라서, 관리자 계정이
# root 로 실행될 바이너리를 갈아치울 수 있다. 그러면 XPC 서명 검증이 무의미해진다.
HELPER_DIR="/Library/PrivilegedHelperTools"
HELPER_DEST="$HELPER_DIR/com.paprika.helperd"
CLI_DEST="/usr/local/bin/paprikactl"
PLIST_DEST="/Library/LaunchDaemons/$LABEL.plist"
SUPPORT_DIR="/Library/Application Support/Paprika"
ALLOW_UNSIGNED_FILE="$SUPPORT_DIR/allow-unsigned-peers"

ALLOW_UNSIGNED=0
[[ "${1:-}" == "--allow-unsigned" ]] && ALLOW_UNSIGNED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 사전 확인

[[ "$(uname -s)" == "Darwin" ]] || die "macOS 전용입니다."
[[ "$(id -u)" == "0" ]] || die "root 로 실행해야 합니다:  sudo $0"

if [[ "$(uname -m)" != "arm64" ]]; then
    warn "Apple Silicon 이 아닌 것 같습니다. 충전 제어가 동작하지 않을 수 있습니다."
fi

# ---------------------------------------------------------------- 소스 찾기
#
# 세 가지 경우를 지원한다:
#   1) 앱 번들 안에서 실행   (Paprika.app/Contents/Resources/install-helper.sh)
#   2) 저장소에서 실행       (Scripts/install-helper.sh, dist/ 또는 .build/ 사용)
#   3) 바이너리를 옆에 둔 경우
#
find_source() {
    local name="$1"
    # 순서가 중요하다: 방금 빌드한 것이 오래된 것보다 먼저 와야 한다.
    local candidates=(
        "$SCRIPT_DIR/$name"                                        # 앱 번들 Resources (스크립트/plist)
        "$SCRIPT_DIR/../Helpers/$name"                             # 앱 번들 Helpers (바이너리)
        "$SCRIPT_DIR/../dist/Paprika.app/Contents/Helpers/$name"   # 저장소의 dist/
        "$SCRIPT_DIR/../dist/Paprika.app/Contents/Resources/$name"
        "$SCRIPT_DIR/../.build/release/$name"                      # swift build -c release
        "$SCRIPT_DIR/../.build/debug/$name"                        # swift build (디버그)
        "/Applications/Paprika.app/Contents/Helpers/$name"
        "/Applications/Paprika.app/Contents/Resources/$name"
    )
    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            ( cd "$(dirname "$candidate")" && printf '%s/%s\n' "$(pwd)" "$(basename "$candidate")" )
            return 0
        fi
    done
    return 1
}

HELPER_SRC="$(find_source paprikad)" || die "paprikad 바이너리를 찾을 수 없습니다. 먼저 ./Scripts/build.sh 를 실행하세요."
info "도우미 바이너리: $HELPER_SRC"

CLI_SRC="$(find_source paprikactl || true)"
PLIST_SRC="$(find_source com.paprika.helperd.plist || true)"
if [[ -z "${PLIST_SRC:-}" ]]; then
    PLIST_SRC="$SCRIPT_DIR/../Resources/com.paprika.helperd.plist"
fi
[[ -f "$PLIST_SRC" ]] || die "launchd plist 를 찾을 수 없습니다: $PLIST_SRC"

# ---------------------------------------------------------------- 기존 것 정리

if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    info "이미 실행 중인 도우미를 멈춥니다 (SMC 는 자동으로 원상복구됩니다)"
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    # 데몬이 하드웨어를 되돌리고 나갈 시간을 준다.
    sleep 1
fi

# ---------------------------------------------------------------- 설치

info "바이너리 설치"
install -d -o root -g wheel -m 0755 "$HELPER_DIR"
install -o root -g wheel -m 0755 "$HELPER_SRC" "$HELPER_DEST"

# 예전 버전이 /usr/local/libexec 에 남아 있으면 치운다.
if [[ -e /usr/local/libexec/paprikad ]]; then
    warn "예전 위치의 도우미를 제거합니다: /usr/local/libexec/paprikad"
    rm -f /usr/local/libexec/paprikad
fi

if [[ -n "${CLI_SRC:-}" ]]; then
    install -d -o root -g wheel -m 0755 /usr/local/bin
    install -o root -g wheel -m 0755 "$CLI_SRC" "$CLI_DEST"
    info "CLI 설치: $CLI_DEST"
else
    warn "paprikactl 을 찾지 못해 CLI 는 건너뜁니다."
fi

install -d -o root -g wheel -m 0755 "$SUPPORT_DIR"

if [[ "$ALLOW_UNSIGNED" == "1" ]]; then
    touch "$ALLOW_UNSIGNED_FILE"
    chmod 0644 "$ALLOW_UNSIGNED_FILE"
    warn "XPC 피어 서명 검증을 껐습니다 ($ALLOW_UNSIGNED_FILE). 문제를 해결한 뒤 이 파일을 지우세요."
else
    rm -f "$ALLOW_UNSIGNED_FILE"
fi

info "launchd plist 설치"
install -o root -g wheel -m 0644 "$PLIST_SRC" "$PLIST_DEST"

info "데몬 등록"
# enable 이 bootstrap 보다 먼저 와야 한다.
# launchctl disable 상태는 plist 를 지워도, 재부팅해도 남는다. 한 번이라도
# disable 된 라벨이면 bootstrap 은 성공하지만 잡은 절대 실행되지 않는데,
# launchctl print 는 그래도 성공해서 이 스크립트가 "설치 완료"라고 거짓 보고한다.
launchctl enable "system/$LABEL" 2>/dev/null || true
launchctl bootstrap system "$PLIST_DEST"

sleep 1

# ---------------------------------------------------------------- 확인

info "설치 확인"
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    printf '    launchd: 등록됨\n'
else
    die "launchd 에 등록되지 않았습니다. /var/log/paprikad.log 를 확인하세요."
fi

printf '\n'
info "이 맥의 충전 제어 지원 여부"
if "$HELPER_DEST" --check; then
    printf '\n\033[1;32m설치 완료.\033[0m Paprika 앱을 실행하세요.\n'
else
    printf '\n'
    warn "충전 제어에 쓸 수 있는 SMC 키를 찾지 못했습니다."
    warn "앱의 설정 → 고급 → SMC 진단, 또는 'paprikactl smc --all' 결과를 확인해 보세요."
fi

cat <<EOF

로그 보기        tail -f /var/log/paprikad.log
                 log stream --predicate 'subsystem == "com.paprika"' --level info
상태 보기        paprikactl status
전부 제거        sudo $SCRIPT_DIR/uninstall.sh
EOF
