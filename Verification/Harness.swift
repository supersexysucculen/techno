//
//  Harness.swift
//  Verification
//
//  단정(assertion) 도구와 집계.
//
//  원칙: 실패는 조용히 넘기지 않고 전부 출력한다. 성공은 섹션별 개수만 센다
//  (수천 개를 다 찍으면 정작 실패가 안 보인다). --verbose 로 전부 볼 수 있다.
//

import Foundation

final class Verifier {

    struct Section {
        var name: String
        var passed = 0
        var failed = 0
        var notes: [String] = []
        var total: Int { passed + failed }
    }

    private(set) var sections: [Section] = []
    private var current: Int = -1
    let verbose: Bool
    private(set) var failures: [String] = []

    init(verbose: Bool) {
        self.verbose = verbose
    }

    func section(_ name: String) {
        sections.append(Section(name: name))
        current = sections.count - 1
        print("\n\u{001B}[1m[\(sections.count)] \(name)\u{001B}[0m")
    }

    func note(_ text: String) {
        guard current >= 0 else { return }
        sections[current].notes.append(text)
        print("      · \(text)")
    }

    // MARK: 기본 단정

    @discardableResult
    func expect(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") -> Bool {
        if condition {
            sections[current].passed += 1
            if verbose { print("      ok    \(label)") }
        } else {
            sections[current].failed += 1
            let extra = detail()
            let line = "\(sections[current].name) › \(label)" + (extra.isEmpty ? "" : " — \(extra)")
            failures.append(line)
            print("      \u{001B}[31mFAIL\u{001B}[0m  \(label)" + (extra.isEmpty ? "" : " — \(extra)"))
        }
        return condition
    }

    @discardableResult
    func equal<T: Equatable>(_ label: String, _ actual: T, _ expected: T) -> Bool {
        expect(label, actual == expected, "got \(actual), want \(expected)")
    }

    @discardableResult
    func close(_ label: String, _ actual: Double, _ expected: Double, tolerance: Double = 0.05) -> Bool {
        expect(
            label,
            abs(actual - expected) <= tolerance,
            String(format: "got %.4f, want %.4f (±%.4f)", actual, expected, tolerance)
        )
    }

    @discardableResult
    func isNil<T>(_ label: String, _ value: T?) -> Bool {
        expect(label, value == nil, "got \(String(describing: value))")
    }

    @discardableResult
    func notNil<T>(_ label: String, _ value: T?) -> Bool {
        expect(label, value != nil, "got nil")
    }

    /// 스윕에서 쓰는 집계형 단정.
    ///
    /// 케이스마다 결과를 찍으면 수천 줄이 되므로, 위반 사례만 모아서 하나의 단정으로
    /// 보고한다. 대신 "몇 개 케이스를 봤는지"를 함께 남긴다.
    func sweep(
        _ label: String,
        cases caseCount: Int,
        violations: [String],
        maxShown: Int = 5
    ) {
        if violations.isEmpty {
            sections[current].passed += 1
            print("      ok    \(label) — \(caseCount)개 케이스 전부 통과")
        } else {
            sections[current].failed += 1
            let shown = violations.prefix(maxShown).joined(separator: "; ")
            let more = violations.count > maxShown ? " (외 \(violations.count - maxShown)건)" : ""
            let line = "\(sections[current].name) › \(label) — \(violations.count)/\(caseCount) 위반: \(shown)\(more)"
            failures.append(line)
            print("      \u{001B}[31mFAIL\u{001B}[0m  \(label) — \(violations.count)/\(caseCount) 위반")
            for violation in violations.prefix(maxShown) {
                print("              \(violation)")
            }
            if violations.count > maxShown {
                print("              … 외 \(violations.count - maxShown)건")
            }
        }
    }

    // MARK: 집계

    var totalPassed: Int { sections.reduce(0) { $0 + $1.passed } }
    var totalFailed: Int { sections.reduce(0) { $0 + $1.failed } }
    var total: Int { totalPassed + totalFailed }

    func summary(sweptCases: Int, simulatedTicks: Int) -> Bool {
        print("\n" + String(repeating: "=", count: 72))
        print("\u{001B}[1m검증 요약\u{001B}[0m")
        print(String(repeating: "-", count: 72))
        for (index, section) in sections.enumerated() {
            let status = section.failed == 0 ? "\u{001B}[32m통과\u{001B}[0m" : "\u{001B}[31m실패\u{001B}[0m"
            // %@ 는 리눅스 Foundation 에서 신뢰할 수 없으므로 직접 정렬한다.
            let rawName = section.name.count > 44
                ? String(section.name.prefix(43)) + "…"
                : section.name
            let name = rawName.padding(toLength: 45, withPad: " ", startingAt: 0)
            let count = String(section.total).padding(toLength: 6, withPad: " ", startingAt: 0)
            let index2 = String(index + 1).padding(toLength: 3, withPad: " ", startingAt: 0)
            print("  \(index2) \(name) \(count)개  \(status)")
        }
        print(String(repeating: "-", count: 72))
        print("  검사 지점(단정)   : \(total)개  (통과 \(totalPassed) / 실패 \(totalFailed))")
        print("  개별 케이스       : \(sweptCases)개")
        print("    └ 전수 스윕은 수천~수십만 개의 서로 다른 입력을 하나의 단정으로")
        print("      묶어서 보고한다. 위반이 하나라도 있으면 그 단정이 실패한다.")
        print("  시뮬레이션 tick   : \(simulatedTicks)회")
        print("  검사 총 횟수      : \(total + sweptCases + simulatedTicks)회")
        print(String(repeating: "=", count: 72))

        if failures.isEmpty {
            print("\n\u{001B}[1;32m전부 통과.\u{001B}[0m")
            return true
        }
        print("\n\u{001B}[1;31m실패 \(failures.count)건:\u{001B}[0m")
        for failure in failures {
            print("  - \(failure)")
        }
        return false
    }
}

// MARK: - 공용 빌더

enum Make {

    static func capabilities(
        backend: ChargeControlBackend,
        adapter: AdapterControlKey = .ch0i,
        firmwareKeys: Bool? = nil,
        magSafe: Bool = true
    ) -> HardwareCapabilities {
        var caps = HardwareCapabilities()
        caps.backend = backend
        caps.adapterKey = adapter
        caps.hasDirectKeys = backend.allowsDirectControl
        caps.hasFirmwareLimitKeys = firmwareKeys ?? (backend == .firmware)
        caps.hasMagSafeLED = magSafe
        return caps
    }

    static func inputs(
        percent: Double,
        plugged: Bool = true,
        charging: Bool = true,
        full: Bool = false,
        present: Bool = true,
        temperature: Double? = 30,
        now: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> PolicyInputs {
        PolicyInputs(
            percent: percent,
            isPluggedIn: plugged,
            isCharging: charging,
            fullyCharged: full,
            batteryPresent: present,
            temperature: temperature,
            now: now
        )
    }

    static func config(
        limit: Int = 80,
        sail: Int = 5,
        discharge: Bool = false,
        tolerance: Int = 2,
        tempGuard: Bool = true,
        tempLimit: Double = 40,
        enabled: Bool = true
    ) -> PaprikaConfig {
        var config = PaprikaConfig()
        config.limit = limit
        config.sail = sail
        config.allowForcedDischarge = discharge
        config.dischargeTolerance = tolerance
        config.temperatureGuardEnabled = tempGuard
        config.temperatureLimit = tempLimit
        config.managementEnabled = enabled
        return config.sanitized()
    }

    /// Apple Silicon 형태의 AppleSmartBattery 속성 딕셔너리.
    static func batteryProperties(
        percent: Int,
        charging: Bool = true,
        plugged: Bool = true,
        full: Bool = false,
        designCapacity: Int = 5300,
        nominalCapacity: Int = 4982,
        temperatureCenti: Int = 3055,
        voltageMillivolts: Int = 12_450,
        amperageMilliamps: Int = 1820,
        cycles: Int = 142
    ) -> [String: Any] {
        [
            "BatteryInstalled": true,
            "IsCharging": charging,
            "ExternalConnected": plugged,
            "FullyCharged": full,
            "CurrentCapacity": percent,
            "MaxCapacity": 100,
            "AppleRawCurrentCapacity": Int(Double(nominalCapacity) * Double(percent) / 100.0),
            "AppleRawMaxCapacity": nominalCapacity,
            "DesignCapacity": designCapacity,
            "NominalChargeCapacity": nominalCapacity,
            "CycleCount": cycles,
            "Voltage": voltageMillivolts,
            "Amperage": amperageMilliamps,
            "Temperature": temperatureCenti,
        ]
    }
}

func describe(_ decision: ChargeDecision) -> String {
    "\(decision.action.rawValue)/\(decision.reason.rawValue)"
}
