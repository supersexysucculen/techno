# Paprika — 맥북 배터리 충전 상한 지킴이
#
# 흔한 흐름:
#     make app        빌드 + Paprika.app 번들 만들기
#     make install    도우미 설치 (sudo 물어봄)
#     make run        앱 실행
#     make status     현재 상태 출력
#     make uninstall  전부 제거

SHELL := /bin/bash
DIST := dist
APP := $(DIST)/Paprika.app
APPLICATIONS := /Applications/Paprika.app

.DEFAULT_GOAL := help

.PHONY: help
help: ## 이 도움말 보기
	@echo "Paprika — make 타깃"
	@echo
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: build
build: ## 릴리스 바이너리만 빌드
	swift build -c release

.PHONY: debug
debug: ## 디버그 빌드
	swift build

.PHONY: app
app: ## 빌드 + Paprika.app 번들 + ad-hoc 서명
	./Scripts/build.sh

.PHONY: install
install: app ## 도우미 설치 (sudo)
	sudo ./Scripts/install-helper.sh

.PHONY: install-unsigned
install-unsigned: app ## 도우미 설치 + XPC 서명 검증 끄기 (문제 해결용)
	sudo ./Scripts/install-helper.sh --allow-unsigned

.PHONY: deploy
deploy: app ## Paprika.app 을 /Applications 로 복사
	@if pgrep -x Paprika >/dev/null; then \
		echo "실행 중인 Paprika 를 종료합니다"; \
		pkill -x Paprika || true; sleep 1; \
	fi
	rm -rf "$(APPLICATIONS)"
	cp -R "$(APP)" "$(APPLICATIONS)"
	@echo "복사 완료: $(APPLICATIONS)"

.PHONY: run
run: ## 앱 실행 (번들이 없으면 먼저 만든다)
	@test -d "$(APP)" || ./Scripts/build.sh
	open "$(APP)"

.PHONY: check
check: ## 도우미 없이 SMC 지원 여부만 확인 (sudo)
	swift build -c release
	sudo "$$(swift build -c release --show-bin-path)/paprikad" --check

.PHONY: status
status: ## paprikactl status
	@if command -v paprikactl >/dev/null; then \
		paprikactl status; \
	else \
		"$$(swift build -c release --show-bin-path)/paprikactl" status; \
	fi

.PHONY: smc
smc: ## SMC 진단 덤프
	@if command -v paprikactl >/dev/null; then \
		paprikactl smc; \
	else \
		"$$(swift build -c release --show-bin-path)/paprikactl" smc; \
	fi

.PHONY: logs
logs: ## 데몬 로그 따라가기
	log stream --predicate 'subsystem == "com.paprika"' --level info

.PHONY: uninstall
uninstall: ## 도우미와 시스템 파일 제거 (sudo)
	sudo ./Scripts/uninstall.sh

.PHONY: uninstall-all
uninstall-all: ## 사용자 설정/기록까지 모두 제거 (sudo)
	sudo ./Scripts/uninstall.sh --all

.PHONY: clean
clean: ## 빌드 산출물 삭제
	rm -rf .build $(DIST)
