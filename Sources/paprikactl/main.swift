//
//  main.swift
//  paprikactl — Paprika 커맨드라인 도구
//
//  GUI 없이 상태를 보고 설정을 바꿀 수 있다. 무언가 이상할 때 여기서 확인하는 게
//  가장 빠르다.
//
//      paprikactl status
//      paprikactl limit 80
//      paprikactl smc --all
//

import Foundation
import PaprikaKit

// CLI 는 메인 스레드를 세마포어로 막으므로, 응답은 백그라운드 큐에서 받아야 한다.
private let replyQueue = DispatchQueue(label: "com.paprika.cli.reply")
private let client = HelperConnection(timeout: 10, completionQueue: replyQueue)

private func printErr(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// 비동기 호출을 동기적으로 기다린다.
private func waitFor<T>(
    _ body: (@escaping (Result<T, Error>) -> Void) -> Void,
    timeout: TimeInterval = 70
) -> Result<T, Error> {
    let semaphore = DispatchSemaphore(value: 0)
    var outcome: Result<T, Error> = .failure(HelperClientError.timeout)
    body { result in
        outcome = result
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + timeout)
    return outcome
}

private func requireSnapshot(_ result: Result<PaprikaSnapshot, Error>) -> PaprikaSnapshot {
    switch result {
    case .success(let snapshot):
        return snapshot
    case .failure(let error):
        printErr("오류: \(error.localizedDescription)")
        if case HelperClientError.notInstalled = error {
            printErr("설치: sudo ./Scripts/install-helper.sh")
        }
        exit(1)
    }
}

private func currentSnapshot() -> PaprikaSnapshot {
    requireSnapshot(waitFor { client.fetchSnapshot(completion: $0) })
}

private func mutateConfig(_ transform: (inout PaprikaConfig) -> Void) -> PaprikaSnapshot {
    var config = currentSnapshot().config
    transform(&config)
    return requireSnapshot(waitFor { client.update(config: config, completion: $0) })
}

private func send(_ command: PaprikaCommand, payload: Data? = nil) -> PaprikaSnapshot {
    requireSnapshot(waitFor { client.perform(command, payload: payload, completion: $0) })
}

// MARK: - 출력

private func printStatus(_ snapshot: PaprikaSnapshot) {
    let battery = snapshot.battery
    let config = snapshot.config
    let decision = snapshot.decision

    print("배터리        : \(String(format: "%.1f%%", snapshot.displayPercent))"
        + (battery.isCharging ? " (충전 중)" : "")
        + (battery.isPluggedIn ? " [전원 연결]" : " [배터리]"))
    print("상태          : \(decision.action.label) — \(decision.reason.label)")
    if let detail = decision.detail {
        print("              \(detail)")
    }
    print("상한          : \(config.limit)%  (재충전 \(config.resumeThreshold)% 이하)")
    print("관리          : \(config.managementEnabled ? "켜짐" : "꺼짐")")
    if let pausedUntil = snapshot.session.pausedUntil, pausedUntil > Date() {
        print("일시중지      : \(pausedUntil) 까지")
    }
    if snapshot.session.fullChargeOnce {
        print("예약          : 이번 한 번만 100% 충전")
    }
    if let calibration = snapshot.session.calibration {
        print("캘리브레이션  : \(calibration.phase.label) (시작 \(calibration.startedAt))")
    }
    print("강제 방전     : \(config.allowForcedDischarge ? "허용" : "안 함") (여유 \(config.dischargeTolerance)%)")
    print("온도 보호     : \(config.temperatureGuardEnabled ? String(format: "%.0f°C", config.temperatureLimit) : "꺼짐")"
        + (snapshot.session.temperatureGuardActive ? "  ← 지금 작동 중" : ""))
    print("")
    print("제어 방식     : \(snapshot.capabilities.backend.rawValue) (\(snapshot.capabilities.backend.label))")
    print("어댑터 키     : \(snapshot.capabilities.adapterKey.rawValue.isEmpty ? "없음" : snapshot.capabilities.adapterKey.rawValue)")
    print("하드웨어      : 충전허용=\(snapshot.hardwareChargingAllowed) 어댑터=\(snapshot.hardwareAdapterEnabled)"
        + (snapshot.hardwareMatchesDecision ? "" : "  ← 판단과 불일치(다음 루프에서 교정)"))
    if let firmwareLimit = snapshot.firmwareLimit {
        print("펌웨어 제한   : \(firmwareLimit.active ? "\(firmwareLimit.lower)–\(firmwareLimit.upper)%" : "비활성")")
    }
    print("")
    print("사이클        : \(battery.cycleCount)")
    if let health = battery.healthPercent {
        print("건강도        : \(String(format: "%.1f%%", health)) (\(battery.nominalCapacity)/\(battery.designCapacity) mAh)")
    }
    if let temperature = battery.temperature {
        print("온도          : \(String(format: "%.1f°C", temperature))")
    }
    if let watts = battery.batteryWatts ?? snapshot.telemetry.batteryWatts {
        print("배터리 전력   : \(String(format: "%+.2f W", watts))")
    }
    if let adapterWatts = snapshot.telemetry.adapterWatts {
        print("어댑터 입력   : \(String(format: "%.2f W", adapterWatts))")
    }
    print("")
    print("도우미        : paprikad \(snapshot.helperVersion), 가동 \(Fmt.short(since: snapshot.daemonStartedAt))")
    if let error = snapshot.lastError {
        print("최근 오류     : \(error)")
    }
}

private enum Fmt {
    static func short(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)초" }
        if seconds < 3600 { return "\(seconds / 60)분" }
        if seconds < 86_400 { return "\(seconds / 3600)시간 \((seconds % 3600) / 60)분" }
        return "\(seconds / 86_400)일"
    }
}

private func printJSON<T: Encodable>(_ value: T) {
    guard let data = try? PaprikaCoding.encode(value, prettyPrinted: true),
          let text = String(data: data, encoding: .utf8)
    else {
        printErr("JSON 인코딩에 실패했습니다.")
        exit(1)
    }
    print(text)
}

private func usage() -> Never {
    print("""
    paprikactl \(PaprikaVersion.current) — Paprika 커맨드라인 도구

    상태
      status                    현재 상태를 사람이 읽기 좋게 출력
      json                      스냅샷 전체를 JSON 으로 출력
      events                    최근 이벤트 로그
      helper                    도우미 연결 상태만 확인

    설정
      limit <20-100>            충전 상한
      sail <0-30>               히스테리시스(재충전 여유)
      on | off                  충전 관리 켜기/끄기
      discharge on|off          상한 초과 시 강제 방전
      temp off | temp <25-55>   온도 보호
      interval <2-60>           제어 루프 주기(초)

    동작
      full                      이번 한 번만 100% 까지 충전
      full cancel               위 예약 취소
      pause <분>                잠시 관리 멈추기
      resume                    다시 시작
      calibrate start|stop      배터리 캘리브레이션
      reset                     SMC 를 기본 상태로 되돌리기
      redetect                  하드웨어 기능 재탐지

    진단
      smc [--all]               SMC 키 덤프 (--all 은 전체 열거, 느림)
      smc --json [--all]        위를 JSON 으로

    예시
      paprikactl limit 80
      paprikactl pause 120
      paprikactl smc --all > ~/Desktop/paprika-smc.txt
    """)
    exit(0)
}

// MARK: - 명령 해석

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }
let rest = Array(arguments.dropFirst())

func intArgument(_ index: Int = 0, name: String) -> Int {
    guard rest.count > index, let value = Int(rest[index]) else {
        printErr("\(name) 값이 필요합니다. 예: paprikactl \(command) 80")
        exit(2)
    }
    return value
}

switch command {
case "status", "":
    printStatus(currentSnapshot())

case "json":
    printJSON(currentSnapshot())

case "helper":
    switch waitFor({ client.handshake(completion: $0) }) {
    case .success(let state):
        switch state {
        case .ready(let version, let protocolVersion):
            print("연결됨: paprikad \(version), protocol \(protocolVersion)")
            if protocolVersion != PaprikaIPC.protocolVersion {
                print("경고: 이 CLI 의 protocol 은 \(PaprikaIPC.protocolVersion) 입니다. 도우미를 다시 설치하세요.")
                exit(1)
            }
        case .notInstalled:
            print("설치되지 않음. sudo ./Scripts/install-helper.sh")
            exit(1)
        case .unreachable(let detail):
            print("연결 불가: \(detail)")
            exit(1)
        case .unknown:
            print("알 수 없음")
            exit(1)
        }
    case .failure(let error):
        printErr("오류: \(error.localizedDescription)")
        exit(1)
    }

case "events":
    for event in currentSnapshot().recentEvents {
        let stamp = ISO8601DateFormatter().string(from: event.date)
        let percent = event.percent.map { String(format: " [%.1f%%]", $0) } ?? ""
        print("\(stamp) \(event.kind.rawValue)\(percent): \(event.message)")
    }

case "limit":
    let value = intArgument(name: "상한")
    let snapshot = mutateConfig { $0.limit = value }
    print("상한을 \(snapshot.config.limit)% 로 설정했습니다. (재충전 \(snapshot.config.resumeThreshold)% 이하)")

case "sail":
    let value = intArgument(name: "히스테리시스")
    let snapshot = mutateConfig { $0.sail = value }
    print("히스테리시스를 \(snapshot.config.sail)% 로 설정했습니다. (재충전 \(snapshot.config.resumeThreshold)% 이하)")

case "interval":
    let value = intArgument(name: "주기")
    let snapshot = mutateConfig { $0.pollInterval = Double(value) }
    print("제어 루프 주기를 \(Int(snapshot.config.pollInterval))초로 설정했습니다.")

case "on":
    _ = mutateConfig { $0.managementEnabled = true }
    print("충전 관리를 켰습니다.")

case "off":
    _ = mutateConfig { $0.managementEnabled = false }
    print("충전 관리를 껐습니다. (SMC 는 기본 상태로 되돌렸습니다)")

case "discharge":
    guard let mode = rest.first, mode == "on" || mode == "off" else {
        printErr("사용법: paprikactl discharge on|off")
        exit(2)
    }
    let snapshot = mutateConfig { $0.allowForcedDischarge = (mode == "on") }
    if mode == "on", !snapshot.capabilities.supportsAdapterControl {
        print("설정은 저장했지만, 이 맥에는 어댑터 제어 키가 없어 강제 방전이 동작하지 않습니다.")
    } else {
        print("강제 방전을 \(mode == "on" ? "켰습니다" : "껐습니다").")
    }

case "temp":
    guard let value = rest.first else {
        printErr("사용법: paprikactl temp off | paprikactl temp 40")
        exit(2)
    }
    if value == "off" {
        _ = mutateConfig { $0.temperatureGuardEnabled = false }
        print("온도 보호를 껐습니다.")
    } else if let celsius = Double(value) {
        let snapshot = mutateConfig {
            $0.temperatureGuardEnabled = true
            $0.temperatureLimit = celsius
        }
        print("온도 보호를 \(String(format: "%.0f°C", snapshot.config.temperatureLimit)) 로 설정했습니다.")
    } else {
        printErr("사용법: paprikactl temp off | paprikactl temp 40")
        exit(2)
    }

case "full":
    if rest.first == "cancel" {
        _ = send(.cancelFullChargeOnce)
        print("100% 한 번 충전 예약을 취소했습니다.")
    } else {
        _ = send(.fullChargeOnce)
        print("이번 한 번만 100% 까지 충전합니다. 완료되면 원래 상한으로 돌아갑니다.")
    }

case "pause":
    let minutes = intArgument(name: "분")
    let payload = try? PaprikaCoding.encode(PauseRequest(minutes: minutes))
    let snapshot = send(.pause, payload: payload)
    if let until = snapshot.session.pausedUntil {
        print("\(minutes)분간 관리를 멈춥니다. (\(until) 까지)")
    } else {
        print("\(minutes)분간 관리를 멈춥니다.")
    }

case "resume":
    _ = send(.resume)
    print("충전 관리를 다시 시작했습니다.")

case "calibrate":
    switch rest.first {
    case "start":
        let snapshot = send(.startCalibration)
        print("캘리브레이션을 시작했습니다: \(snapshot.config.calibrationFloor)% 까지 방전 → 100% → \(snapshot.config.calibrationSettleMinutes)분 유지")
    case "stop":
        _ = send(.cancelCalibration)
        print("캘리브레이션을 중지했습니다.")
    default:
        printErr("사용법: paprikactl calibrate start|stop")
        exit(2)
    }

case "reset":
    _ = send(.resetHardware)
    print("SMC 를 기본 상태로 되돌렸습니다. (관리가 켜져 있으면 곧 다시 적용됩니다)")

case "redetect":
    let snapshot = send(.redetectHardware)
    print("다시 탐지했습니다: \(snapshot.capabilities.backend.rawValue)")

case "smc":
    let includeAll = rest.contains("--all")
    let asJSON = rest.contains("--json")
    switch waitFor({ client.smcDump(includeAllKeys: includeAll, completion: $0) }) {
    case .success(let dump):
        if asJSON { printJSON(dump) } else { print(dump.plainText()) }
    case .failure(let error):
        printErr("오류: \(error.localizedDescription)")
        exit(1)
    }

case "help", "--help", "-h":
    usage()

case "version", "--version":
    print("paprikactl \(PaprikaVersion.current) (protocol \(PaprikaIPC.protocolVersion))")

default:
    printErr("알 수 없는 명령: \(command)")
    printErr("paprikactl help 로 사용법을 확인하세요.")
    exit(2)
}
