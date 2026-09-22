#!/bin/bash
#
# verify.sh — Paprika 검증 하니스 실행.
#
#   ./Scripts/verify.sh              전체 실행
#   ./Scripts/verify.sh --verbose    통과한 단정까지 전부 출력
#
# macOS 와 Linux 둘 다에서 돌아간다. 그게 요점이다 — 충전 제어 로직을 맥 없이도
# 실제로 실행해볼 수 있게 하려고 PaprikaKit 의 플랫폼 독립 부분을 따로 떼어두었다.
#
# 아래 파일 목록이 "맥 없이도 검증 가능한 범위"의 정의다.
# IOKit / AppKit / SwiftUI / XPC 를 쓰는 파일은 여기 없다.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUILD_DIR=".build/verification"

info() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

command -v swiftc >/dev/null || die "swiftc 를 찾을 수 없습니다."

# ---------------------------------------------------------------------------
# 플랫폼에 의존하지 않는 PaprikaKit 소스.
# 여기 있는 건 전부 앱에 실제로 들어가는 코드다(대체 구현 없음).
# ---------------------------------------------------------------------------
KIT_SOURCES=(
    "Sources/PaprikaKit/Support/Localization.swift"
    "Sources/PaprikaKit/SMC/SMCParamStruct.swift"
    "Sources/PaprikaKit/SMC/SMCValue.swift"
    "Sources/PaprikaKit/SMC/SMCAccess.swift"
    "Sources/PaprikaKit/SMC/SMCKeys.swift"
    "Sources/PaprikaKit/Battery/BatteryInfo.swift"
    "Sources/PaprikaKit/Battery/BatteryPropertyParser.swift"
    "Sources/PaprikaKit/Hardware/ChargeHardware.swift"
    "Sources/PaprikaKit/Hardware/ChargeApplier.swift"
    "Sources/PaprikaKit/Policy/PaprikaConfig.swift"
    "Sources/PaprikaKit/Policy/PaprikaEvent.swift"
    "Sources/PaprikaKit/Policy/ChargePolicy.swift"
)

# 검증 하니스. Shims.swift 가 PaprikaLog(os.Logger) 와 SystemInfo(sysctl) 만 대체한다.
VERIFY_SOURCES=(
    "Verification/Shims.swift"
    "Verification/FakeSMC.swift"
    "Verification/Harness.swift"
    "Verification/LowLevelChecks.swift"
    "Verification/PolicyChecks.swift"
    "Verification/HardwareChecks.swift"
    "Verification/Simulation.swift"
    "Verification/main.swift"
)

for source in "${KIT_SOURCES[@]}" "${VERIFY_SOURCES[@]}"; do
    [[ -f "$source" ]] || die "소스를 찾을 수 없습니다: $source"
done

# PaprikaCoding(JSON 인코딩)은 IPC 파일에 있는데 그 파일은 XPC 에 의존한다.
# 검증에 필요한 부분만 여기서 만들어 쓴다.
mkdir -p "$BUILD_DIR"
cat > "$BUILD_DIR/CodingShim.swift" <<'SWIFT'
// PaprikaCoding 은 IPC/PaprikaSnapshot.swift 에 있고, 그 파일은 XPC 를 쓰는
// HelperProtocol 과 한 묶음이다. 검증에는 JSON 인코딩만 필요하므로 같은 설정으로
// 여기서 정의한다. (실제 앱은 IPC 쪽 정의를 쓴다)
import Foundation

public enum PaprikaCoding {
    public static func encoder(prettyPrinted: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if prettyPrinted { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode<T: Encodable>(_ value: T, prettyPrinted: Bool = false) throws -> Data {
        try encoder(prettyPrinted: prettyPrinted).encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }
}
SWIFT

info "컴파일 (${#KIT_SOURCES[@]}개 실제 소스 + ${#VERIFY_SOURCES[@]}개 검증 소스)"
swiftc -O \
    -o "$BUILD_DIR/paprika-verify" \
    "${KIT_SOURCES[@]}" "${VERIFY_SOURCES[@]}" "$BUILD_DIR/CodingShim.swift"

info "실행"
echo
"$BUILD_DIR/paprika-verify" "$@"
