#!/bin/bash
#
# uninstall.sh — Paprika 가 시스템에 넣은 것을 모두 되돌린다.
#
#   sudo ./Scripts/uninstall.sh              도우미 + 시스템 파일 제거
#   sudo ./Scripts/uninstall.sh --all        사용자 설정/기록까지 제거
#
# 중요: 데몬을 멈추면 SMC 가 자동으로 기본 상태(충전 허용)로 돌아간다.
#       그래도 확실히 하려고 아래에서 한 번 더 확인한다.
#
set -euo pipefail

LABEL="com.paprika.helperd"
HELPER_DEST="/Library/PrivilegedHelperTools/com.paprika.helperd"
LEGACY_HELPER_DEST="/usr/local/libexec/paprikad"
CLI_DEST="/usr/local/bin/paprikactl"
PLIST_DEST="/Library/LaunchDaemons/$LABEL.plist"
SUPPORT_DIR="/Library/Application Support/Paprika"
LOG_FILE="/var/log/paprikad.log"

REMOVE_USER_DATA=0
[[ "${1:-}" == "--all" ]] && REMOVE_USER_DATA=1

info()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" == "0" ]] || die "root 로 실행해야 합니다:  sudo $0"

# ---------------------------------------------------------- 1. 충전 제한 해제

if [[ -x "$CLI_DEST" ]] && launchctl print "system/$LABEL" >/dev/null 2>&1; then
    info "충전 관리를 끄고 SMC 를 되돌립니다"
    "$CLI_DEST" off  >/dev/null 2>&1 || true
    "$CLI_DEST" reset >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------- 2. 데몬 정지

if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    info "데몬 정지 (종료 시 SMC 를 원상복구합니다)"
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    # 데몬이 복구 쓰기를 끝내고 나갈 시간을 준다.
    sleep 2
else
    info "데몬이 실행 중이 아닙니다"
fi

# ---------------------------------------------------------- 3. 안전망
#
# 위의 두 단계는 각각 조건이 붙는다(CLI 가 있어야 함 / 데몬이 살아 있어야 함).
# 둘 다 실패했는데 충전이 막힌 상태라면, 바이너리를 지우는 순간 되돌릴 방법이
# 사라진다. 그래서 여기서 --restore 로 SMC 를 직접 되돌린다.
# 이건 데몬도 CLI 도 없어도 동작한다.
RESTORE_OK=0
for candidate in "$HELPER_DEST" "$LEGACY_HELPER_DEST"; do
    if [[ -x "$candidate" ]]; then
        info "SMC 직접 복구: $candidate --restore"
        if "$candidate" --restore 2>&1 | sed 's/^/    /'; then
            RESTORE_OK=1
        else
            warn "복구가 완전히 끝나지 않았습니다. 아래 안내를 확인하세요."
        fi
        break
    fi
done
if [[ "$RESTORE_OK" == "0" ]]; then
    warn "도우미 바이너리로 복구하지 못했습니다."
    warn "충전이 막힌 상태로 남았다면 맥을 완전히 껐다 켜세요."
fi

# ---------------------------------------------------------- 4. 파일 제거

info "시스템 파일 제거"
for path in "$PLIST_DEST" "$HELPER_DEST" "$LEGACY_HELPER_DEST" "$CLI_DEST"; do
    if [[ -e "$path" ]]; then
        rm -f "$path"
        printf '    제거: %s\n' "$path"
    fi
done

# disable 상태는 plist 를 지워도 남는다. 다음에 다시 설치할 때 조용히 실행되지
# 않는 일을 막으려면 여기서 지워야 한다.
launchctl enable "system/$LABEL" 2>/dev/null || true

if [[ -d "$SUPPORT_DIR" ]]; then
    rm -rf "$SUPPORT_DIR"
    printf '    제거: %s\n' "$SUPPORT_DIR"
fi

if [[ -f "$LOG_FILE" ]]; then
    rm -f "$LOG_FILE"
    printf '    제거: %s\n' "$LOG_FILE"
fi

# ---------------------------------------------------------- 5. 사용자 데이터

CONSOLE_USER="$(stat -f '%Su' /dev/console 2>/dev/null || echo "")"
if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" ]]; then
    USER_HOME="$(eval echo "~$CONSOLE_USER")"
    USER_SUPPORT="$USER_HOME/Library/Application Support/Paprika"
    LOGIN_AGENT="$USER_HOME/Library/LaunchAgents/com.paprika.Paprika.login.plist"

    if [[ -f "$LOGIN_AGENT" ]]; then
        info "로그인 항목 제거"
        sudo -u "$CONSOLE_USER" launchctl bootout "gui/$(id -u "$CONSOLE_USER")/com.paprika.Paprika.login" 2>/dev/null || true
        rm -f "$LOGIN_AGENT"
        printf '    제거: %s\n' "$LOGIN_AGENT"
    fi

    if [[ "$REMOVE_USER_DATA" == "1" ]]; then
        if [[ -d "$USER_SUPPORT" ]]; then
            rm -rf "$USER_SUPPORT"
            printf '    제거: %s\n' "$USER_SUPPORT"
        fi
        sudo -u "$CONSOLE_USER" defaults delete com.paprika.Paprika 2>/dev/null || true
        printf '    제거: UserDefaults (com.paprika.Paprika)\n'
    elif [[ -d "$USER_SUPPORT" ]]; then
        warn "기록은 남겨두었습니다: $USER_SUPPORT  (--all 로 실행하면 함께 삭제합니다)"
    fi
fi

cat <<'EOF'

제거 완료.

남은 일
  * 실행 중인 Paprika 앱이 있으면 종료하고, Paprika.app 을 휴지통에 버리세요.
  * 충전 동작이 여전히 이상하면 맥을 완전히 껐다 켜세요.
    (전원 재투입 시 SMC 값이 초기화됩니다)
EOF
