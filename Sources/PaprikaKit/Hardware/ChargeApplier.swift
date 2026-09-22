//
//  ChargeApplier.swift
//  PaprikaKit
//
//  정책 엔진의 판단(ChargeDecision)을 실제 SMC 상태로 옮기는 계층.
//
//  왜 데몬이 아니라 여기 있나
//  ------------------------
//  이 매핑이 틀리면 결과가 "충전이 영구히 막힘"이다. 이 앱에서 가장 위험한 코드다.
//  ChargeController 안에 있으면 IOKit·XPC·타이머에 얽혀 실행 검증이 불가능하므로,
//  ChargeHardware(= SMCAccess 프로토콜) 만 받는 독립 함수로 떼어냈다.
//  덕분에 Verification/ 하니스가 모든 백엔드 × 모든 동작 조합을 실제로 돌려본다.
//
//  백엔드별 차이
//  ------------
//  * 직접 제어(CH0B/CH0C, CHTE): 충전을 초 단위로 켜고 끈다. 펌웨어 제한이 동시에
//    걸려 있으면 서로 싸우므로 먼저 해제한다.
//  * 펌웨어 위임(bfF0/bfD0/bfE0): 상·하한만 알려주면 펌웨어가 히스테리시스까지
//    관리한다. 우리가 초 단위로 개입할 수는 없다.
//

import Foundation

public struct ChargeApplyResult: Equatable, Sendable {
    /// SMC 에 실제로 쓴 값이 있었는지. (없으면 이미 원하는 상태였다는 뜻)
    public var changed: Bool = false
    /// 실패했다면 사람이 읽을 수 있는 이유.
    public var error: String?
    /// 디버깅/검증용: 이번에 수행한 동작 목록.
    public var steps: [String] = []

    public init(changed: Bool = false, error: String? = nil, steps: [String] = []) {
        self.changed = changed
        self.error = error
        self.steps = steps
    }
}

public enum ChargeApplier {

    /// 판단을 하드웨어에 반영한다.
    ///
    /// - Parameters:
    ///   - decision: 정책 엔진의 결정.
    ///   - hardware: 대상 하드웨어.
    ///   - controlMagSafeLED: MagSafe LED 색도 상태에 맞춰 바꿀지.
    public static func apply(
        decision: ChargeDecision,
        hardware: ChargeHardware,
        controlMagSafeLED: Bool
    ) -> ChargeApplyResult {
        var result = ChargeApplyResult()
        let capabilities = hardware.capabilities
        guard capabilities.isUsable else { return result }

        /// 어댑터 제어 키가 있을 때만 어댑터 상태를 건드린다.
        func setAdapter(_ enabled: Bool) throws {
            guard capabilities.supportsAdapterControl else { return }
            if try hardware.setAdapter(enabled: enabled) {
                result.changed = true
                result.steps.append(enabled ? "adapter=on" : "adapter=off")
            }
        }

        func setCharging(_ allowed: Bool) throws {
            if try hardware.setCharging(allowed: allowed) {
                result.changed = true
                result.steps.append(allowed ? "charging=on" : "charging=off")
            }
        }

        func setFirmwareRange() throws {
            let upper = decision.effectiveTarget
            let lower = min(max(0, decision.effectiveResumeThreshold), upper - 1)
            if try hardware.setFirmwareLimit(lower: lower, upper: upper) {
                result.changed = true
                result.steps.append("firmwareLimit=\(lower)-\(upper)")
            }
        }

        func clearFirmwareLimit() throws {
            if try hardware.disableFirmwareLimit() {
                result.changed = true
                result.steps.append("firmwareLimit=off")
            }
        }

        do {
            switch capabilities.backend {
            case .classicLegacy, .tahoeLegacy:
                // 펌웨어 제한이 동시에 걸려 있으면 서로 싸운다. 직접 제어할 때는 끈다.
                if capabilities.hasFirmwareLimitKeys {
                    try clearFirmwareLimit()
                }

                switch decision.action {
                case .allowCharging, .unmanaged:
                    try setAdapter(true)
                    try setCharging(true)

                case .inhibitCharging:
                    try setAdapter(true)
                    try setCharging(false)

                case .forceDischarge:
                    try setCharging(false)
                    try setAdapter(false)
                }

            case .firmware:
                switch decision.action {
                case .unmanaged:
                    try clearFirmwareLimit()
                    try setAdapter(true)

                // 상한이 100 이면 제한을 걸 이유가 없다.
                case .allowCharging where decision.effectiveTarget >= 100,
                     .inhibitCharging where decision.effectiveTarget >= 100:
                    try clearFirmwareLimit()
                    try setAdapter(true)

                case .allowCharging, .inhibitCharging:
                    try setFirmwareRange()
                    try setAdapter(true)

                case .forceDischarge:
                    try setFirmwareRange()
                    try setAdapter(false)
                }

            case .unsupported:
                break
            }

            if controlMagSafeLED, capabilities.hasMagSafeLED {
                let state = magSafeState(for: decision.action)
                if try hardware.setMagSafeLED(state) {
                    result.changed = true
                    result.steps.append("magSafeLED=\(state)")
                }
            }
        } catch {
            result.error = String(describing: error)
        }

        return result
    }

    /// 동작에 어울리는 MagSafe LED 색.
    public static func magSafeState(for action: ChargeAction) -> MagSafeLEDState {
        switch action {
        case .allowCharging: return .orange   // 충전 중
        case .inhibitCharging: return .green  // 상한 유지
        case .forceDischarge: return .off
        case .unmanaged: return .system
        }
    }
}
