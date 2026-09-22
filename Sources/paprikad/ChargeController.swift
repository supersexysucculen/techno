//
//  ChargeController.swift
//  paprikad
//
//  데몬의 심장. 주기적으로
//      배터리 읽기 → 정책 판단 → SMC 반영 → 스냅샷 갱신
//  을 반복한다.
//
//  정책 판단을 데몬에 둔 이유: 메뉴바 앱이 죽거나 로그아웃해도 충전 제한이 계속
//  유지돼야 하기 때문이다. 앱은 순수하게 "보여주고 설정을 바꾸는" 역할만 한다.
//
//  안전 원칙
//  --------
//  * 데몬이 정상 종료될 때는 항상 하드웨어를 기본 상태(충전 허용)로 되돌린다.
//  * SMC 쓰기는 값이 실제로 다를 때만 한다.
//  * 판단이 불가능하거나 오류가 나면 "충전 허용" 쪽으로 기운다. 배터리가 텅 빈
//    채로 방치되는 게 100% 로 방치되는 것보다 나쁘다.
//

import Foundation
import PaprikaKit

final class ChargeController {

    enum TickTrigger: String {
        case timer
        case wake
        case powerSource
        case configChange
        case command
        case startup
    }

    private let queue = DispatchQueue(label: "com.paprika.helperd.control", qos: .utility)
    private let batteryReader = BatteryReader()
    private let store = StateStore()

    private var smc: SMCConnection?
    private var hardware: ChargeHardware?
    private var powerWatcher: PowerWatcher?
    private var timer: DispatchSourceTimer?

    private var state: DaemonState
    private var events: [PaprikaEvent] = []
    private var latestSnapshot: PaprikaSnapshot?
    /// SMC 쓰기/연결 오류. applyToHardware 가 성공하면 지워진다.
    private var lastError: String?
    /// 배터리 읽기 오류. 위와 섞이면 서로를 지워버리므로 따로 둔다.
    private var batteryReadError: String?
    /// 같은 오류로 이벤트 로그를 도배하지 않기 위한 기억.
    private var lastReportedErrorText: String?
    private let startedAt = Date()
    private var isShuttingDown = false

    private let maxEvents = 300

    init() {
        state = store.load()
        L.language = .system
    }

    // MARK: - 수명 주기

    func start() {
        queue.async { [self] in
            openHardware()
            appendEvent(PaprikaEvent(
                kind: .daemonLifecycle,
                message: L.s("paprikad \(PaprikaVersion.current) 가 시작되었습니다.", "paprikad \(PaprikaVersion.current) started.")
            ))
            tick(trigger: .startup)
            scheduleTimer()
        }

        // 시스템 알림은 메인 런루프에서 받아야 한다.
        DispatchQueue.main.async { [self] in
            let watcher = PowerWatcher()
            watcher.onWake = { [weak self] in
                guard let self else { return }
                // 깨어난 직후엔 SMC 가 아직 안정되지 않았을 수 있어 조금 기다린다.
                self.queue.asyncAfter(deadline: .now() + 2) {
                    self.tick(trigger: .wake)
                }
            }
            watcher.onPowerSourceChange = { [weak self] in
                self?.queue.async { self?.tick(trigger: .powerSource) }
            }
            watcher.start()
            powerWatcher = watcher
        }
    }

    /// 데몬 종료 경로. 반드시 하드웨어를 되돌린다.
    ///
    /// 동기(`queue.sync`)로 처리하는 이유: 호출한 쪽이 곧바로 `exit(0)` 을 하기 때문에,
    /// 복구 쓰기가 끝나기를 기다려야 한다. 교착은 없다 — 제어 큐 위의 작업은 메인 큐나
    /// XPC 큐를 기다리지 않으므로 이 호출자들(메인 큐의 시그널 소스, XPC 큐의
    /// restoreAndExit)은 항상 진행할 수 있다.
    ///
    /// 참고: main.swift 는 `signal(n, SIG_IGN)` + DispatchSourceSignal 을 쓰므로
    /// 여기는 진짜 시그널 핸들러 문맥이 아니다. 즉 락과 IO 를 써도 된다.
    func shutdown(restoreHardware: Bool) {
        queue.sync { [self] in
            guard !isShuttingDown else { return }
            isShuttingDown = true
            timer?.cancel()
            timer = nil

            // 설정과 무관하게 항상 복구한다. bootout / 언인스톨 / SIGTERM 모두
            // 이 경로를 지나므로, 여기서 빠뜨리면 충전이 막힌 채로 남는다.
            if restoreHardware, let hardware {
                let failures = hardware.restoreDefaults()
                if !failures.isEmpty {
                    PaprikaLog.daemon.error("종료 중 복구 실패: \(failures.joined(separator: "; "), privacy: .public)")
                }
            }
            store.save(state)
            PaprikaLog.daemon.notice("paprikad 종료.")
        }
        DispatchQueue.main.async { [weak self] in
            self?.powerWatcher?.stop()
            self?.powerWatcher = nil
        }
    }

    private func scheduleTimer() {
        timer?.cancel()
        let interval = state.config.pollInterval
        let newTimer = DispatchSource.makeTimerSource(queue: queue)
        newTimer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(500))
        newTimer.setEventHandler { [weak self] in
            self?.tick(trigger: .timer)
        }
        newTimer.resume()
        timer = newTimer
    }

    // MARK: - 하드웨어 열기

    private func openHardware() {
        guard smc == nil else { return }
        do {
            let connection = try SMCConnection()
            let charge = ChargeHardware(smc: connection, forcedBackend: state.config.forcedBackend)
            smc = connection
            hardware = charge

            if !charge.capabilities.system.isAppleSilicon {
                recordError(L.s(
                    "이 앱은 Apple Silicon 전용입니다. 인텔 맥에서는 동작하지 않습니다.",
                    "This build is Apple Silicon only."
                ), kind: .hardwareError)
            } else if charge.capabilities.backend == .unsupported {
                recordError(L.s(
                    "충전 제어에 쓸 수 있는 SMC 키를 찾지 못했습니다. '고급 → SMC 진단'을 확인해 주세요.",
                    "No usable charge-control SMC keys found. See Advanced → SMC diagnostics."
                ), kind: .hardwareError)
            } else {
                clearError()
                appendEvent(PaprikaEvent(
                    kind: .info,
                    message: L.s(
                        "충전 제어 방식: \(charge.capabilities.backend.label)",
                        "Charge control backend: \(charge.capabilities.backend.label)"
                    )
                ))
            }
        } catch {
            recordError(String(describing: error), kind: .hardwareError)
            PaprikaLog.daemon.error("SMC 연결 실패: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - 제어 루프 한 번

    private func tick(trigger: TickTrigger) {
        guard !isShuttingDown else { return }

        if hardware == nil {
            openHardware()
        }

        // 배터리를 읽지 못해도 **그냥 리턴하면 안 된다.**
        //
        // 직전 tick 에서 충전을 막아둔 상태라면, 읽기가 계속 실패하는 동안 그 억제가
        // 하드웨어에 그대로 남는다. 정책 엔진에는 이미 batteryPresent == false 를
        // "관리하지 않음(= 충전 허용)"으로 처리하는 분기가 있으므로, 빈 정보를 만들어
        // 그 분기로 내려보낸다. 그러면 applyToHardware 가 충전을 다시 허용한다.
        var battery: BatteryInfo
        if let reading = batteryReader.read() {
            battery = reading
            if batteryReadError != nil {
                batteryReadError = nil
                appendEvent(PaprikaEvent(
                    kind: .info,
                    message: L.s("배터리 정보를 다시 읽을 수 있습니다.", "Battery information is readable again.")
                ))
            }
        } else {
            battery = BatteryInfo()
            battery.batteryInstalled = false
            let message = L.s(
                "배터리 정보를 읽을 수 없습니다 — 안전을 위해 충전 제한을 해제합니다.",
                "Cannot read battery information — lifting the charge limit to be safe."
            )
            if batteryReadError == nil {
                batteryReadError = message
                appendEvent(PaprikaEvent(kind: .hardwareError, message: message))
            }
        }

        var telemetry = PowerTelemetry()
        if let hardware {
            telemetry = hardware.readTelemetry()
            // IORegistry 에 온도가 없으면 SMC 값으로 메운다.
            if battery.temperature == nil { battery.temperature = telemetry.temperature }
            // AC-W 는 IORegistry 보다 반응이 빠를 때가 있다.
            if let acConnected = telemetry.acConnected { battery.isPluggedIn = acConnected }
        }

        let capabilities = hardware?.capabilities ?? HardwareCapabilities()
        let inputs = PolicyInputs(battery: battery)

        let result = ChargePolicy.evaluate(
            config: state.config,
            session: state.session,
            inputs: inputs,
            capabilities: capabilities
        )

        let sessionChanged = result.session != state.session
        state.session = result.session
        for event in result.events { appendEvent(event) }

        let applied = applyToHardware(decision: result.decision)

        if applied.changed {
            state.session.lastAppliedAction = result.decision.action
            state.session.lastAppliedAt = Date()
            PaprikaLog.policy.info(
                "[\(trigger.rawValue, privacy: .public)] \(result.decision.action.rawValue, privacy: .public) target=\(result.decision.effectiveTarget, privacy: .public) percent=\(String(format: "%.1f", inputs.percent), privacy: .public)"
            )
        } else if state.session.lastAppliedAction == nil {
            state.session.lastAppliedAction = result.decision.action
        }

        latestSnapshot = buildSnapshot(
            battery: battery,
            telemetry: telemetry,
            capabilities: capabilities,
            decision: result.decision
        )

        if sessionChanged || applied.changed {
            store.save(state)
        }
    }

    // MARK: - SMC 반영

    private struct ApplyOutcome {
        var changed: Bool = false
        var error: String?
    }

    private func applyToHardware(decision: ChargeDecision) -> ApplyOutcome {
        guard let hardware else {
            return ApplyOutcome(changed: false, error: L.s("SMC 연결이 없습니다.", "No SMC connection."))
        }

        var outcome = ApplyOutcome()
        let capabilities = hardware.capabilities
        guard capabilities.isUsable else { return outcome }

        /// 어댑터 제어 키가 있을 때만 어댑터 상태를 건드린다.
        func setAdapter(_ enabled: Bool) throws {
            guard capabilities.supportsAdapterControl else { return }
            if try hardware.setAdapter(enabled: enabled) { outcome.changed = true }
        }

        func setCharging(_ allowed: Bool) throws {
            if try hardware.setCharging(allowed: allowed) { outcome.changed = true }
        }

        func setFirmwareRange(_ decision: ChargeDecision) throws {
            let upper = decision.effectiveTarget
            let lower = min(max(0, decision.effectiveResumeThreshold), upper - 1)
            if try hardware.setFirmwareLimit(lower: lower, upper: upper) { outcome.changed = true }
        }

        func clearFirmwareLimit() throws {
            if try hardware.disableFirmwareLimit() { outcome.changed = true }
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
                // 펌웨어가 히스테리시스까지 관리하므로 범위만 알려주면 된다.
                switch decision.action {
                case .unmanaged:
                    try clearFirmwareLimit()
                    try setAdapter(true)

                // 상한이 100 이면 제한을 걸 이유가 없다(방전 요청은 아래에서 따로 본다).
                case .allowCharging where decision.effectiveTarget >= 100,
                     .inhibitCharging where decision.effectiveTarget >= 100:
                    try clearFirmwareLimit()
                    try setAdapter(true)

                case .allowCharging, .inhibitCharging:
                    try setFirmwareRange(decision)
                    try setAdapter(true)

                case .forceDischarge:
                    try setFirmwareRange(decision)
                    try setAdapter(false)
                }

            case .unsupported:
                break
            }

            if state.config.controlMagSafeLED, capabilities.hasMagSafeLED {
                let ledState = magSafeState(for: decision.action)
                if try hardware.setMagSafeLED(ledState) { outcome.changed = true }
            }

            clearError()
        } catch {
            let text = String(describing: error)
            outcome.error = text
            recordError(text, kind: .hardwareError)
        }

        return outcome
    }

    private func magSafeState(for action: ChargeAction) -> MagSafeLEDState {
        switch action {
        case .allowCharging: return .orange
        case .inhibitCharging: return .green
        case .forceDischarge: return .off
        case .unmanaged: return .system
        }
    }

    // MARK: - 스냅샷

    private func buildSnapshot(
        battery: BatteryInfo,
        telemetry: PowerTelemetry,
        capabilities: HardwareCapabilities,
        decision: ChargeDecision
    ) -> PaprikaSnapshot {
        var chargingAllowed = true
        var adapterEnabled = true
        var firmwareLimit: FirmwareChargeLimit?
        var led: MagSafeLEDState?

        if let hardware {
            chargingAllowed = (try? hardware.isChargingAllowed()) ?? true
            adapterEnabled = (try? hardware.isAdapterEnabled()) ?? true
            if capabilities.hasFirmwareLimitKeys {
                firmwareLimit = try? hardware.firmwareLimit()
            }
            if capabilities.hasMagSafeLED {
                led = try? hardware.magSafeLED()
            }
        }

        return PaprikaSnapshot(
            helperVersion: PaprikaVersion.current,
            battery: battery,
            telemetry: telemetry,
            capabilities: capabilities,
            config: state.config,
            session: state.session,
            decision: decision,
            hardwareChargingAllowed: chargingAllowed,
            hardwareAdapterEnabled: adapterEnabled,
            firmwareLimit: firmwareLimit,
            magSafeLED: led,
            daemonStartedAt: startedAt,
            lastError: combinedError,
            recentEvents: Array(events.suffix(120).reversed())
        )
    }

    // MARK: - 이벤트 / 오류

    /// UI 에 보여줄 오류 한 줄. 배터리 읽기 오류가 더 심각하므로 앞에 둔다.
    private var combinedError: String? {
        let parts = [batteryReadError, lastError].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }

    private func appendEvent(_ event: PaprikaEvent) {
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        PaprikaLog.daemon.info("\(event.kind.rawValue, privacy: .public): \(event.message, privacy: .public)")
    }

    private func recordError(_ message: String, kind: PaprikaEvent.Kind) {
        lastError = message
        guard lastReportedErrorText != message else { return }
        lastReportedErrorText = message
        appendEvent(PaprikaEvent(kind: kind, message: message))
    }

    private func clearError() {
        lastError = nil
        lastReportedErrorText = nil
    }

    // MARK: - XPC 에서 들어오는 요청들

    func snapshot(completion: @escaping (Result<PaprikaSnapshot, Error>) -> Void) {
        queue.async { [self] in
            if latestSnapshot == nil { tick(trigger: .command) }
            if let latestSnapshot {
                completion(.success(latestSnapshot))
            } else {
                completion(.failure(PaprikaDaemonError.noSnapshot))
            }
        }
    }

    func updateConfig(_ config: PaprikaConfig, completion: @escaping (Result<PaprikaSnapshot, Error>) -> Void) {
        queue.async { [self] in
            // 종료가 시작된 뒤에 들어온 요청은 무시한다. 받아주면 이미 복구해둔
            // 하드웨어를 다시 건드리고 상태 파일을 덮어쓴다.
            guard !isShuttingDown else {
                completion(.failure(PaprikaDaemonError.shuttingDown))
                return
            }
            let sanitized = config.sanitized()
            let previous = state.config
            guard sanitized != previous else {
                if let latestSnapshot {
                    completion(.success(latestSnapshot))
                } else {
                    completion(.failure(PaprikaDaemonError.noSnapshot))
                }
                return
            }

            state.config = sanitized

            // 관리를 껐다면 즉시 하드웨어를 되돌린다(다음 tick 을 기다리지 않는다).
            if previous.managementEnabled, !sanitized.managementEnabled, let hardware {
                _ = hardware.restoreDefaults()
                state.session.temperatureGuardActive = false
                state.session.lastAppliedAction = .unmanaged
            }

            if previous.forcedBackend != sanitized.forcedBackend {
                hardware?.setForcedBackend(sanitized.forcedBackend)
            }

            if previous.pollInterval != sanitized.pollInterval {
                scheduleTimer()
            }

            appendEvent(PaprikaEvent(
                kind: .configChanged,
                message: configChangeSummary(from: previous, to: sanitized)
            ))

            store.save(state)
            tick(trigger: .configChange)

            if let latestSnapshot {
                completion(.success(latestSnapshot))
            } else {
                completion(.failure(PaprikaDaemonError.noSnapshot))
            }
        }
    }

    private func configChangeSummary(from old: PaprikaConfig, to new: PaprikaConfig) -> String {
        var parts: [String] = []
        if old.limit != new.limit {
            parts.append(L.s("상한 \(old.limit)% → \(new.limit)%", "limit \(old.limit)% → \(new.limit)%"))
        }
        if old.managementEnabled != new.managementEnabled {
            parts.append(new.managementEnabled ? L.s("관리 켜짐", "management on") : L.s("관리 꺼짐", "management off"))
        }
        if old.sail != new.sail {
            parts.append(L.s("히스테리시스 \(new.sail)%", "hysteresis \(new.sail)%"))
        }
        if old.allowForcedDischarge != new.allowForcedDischarge {
            parts.append(new.allowForcedDischarge ? L.s("강제 방전 허용", "forced discharge on") : L.s("강제 방전 해제", "forced discharge off"))
        }
        if old.temperatureGuardEnabled != new.temperatureGuardEnabled || old.temperatureLimit != new.temperatureLimit {
            parts.append(String(
                format: L.s("온도 보호 %@ %.0f°C", "temp guard %@ %.0f°C"),
                new.temperatureGuardEnabled ? "on" : "off",
                new.temperatureLimit
            ))
        }
        if parts.isEmpty {
            parts.append(L.s("설정이 변경되었습니다", "configuration changed"))
        }
        return parts.joined(separator: ", ")
    }

    func perform(
        command: PaprikaCommand,
        payload: Data?,
        completion: @escaping (Result<PaprikaSnapshot, Error>) -> Void
    ) {
        queue.async { [self] in
            guard !isShuttingDown else {
                completion(.failure(PaprikaDaemonError.shuttingDown))
                return
            }
            do {
                try handle(command: command, payload: payload)
            } catch {
                completion(.failure(error))
                return
            }
            store.save(state)
            tick(trigger: .command)
            if let latestSnapshot {
                completion(.success(latestSnapshot))
            } else {
                completion(.failure(PaprikaDaemonError.noSnapshot))
            }
        }
    }

    private func handle(command: PaprikaCommand, payload: Data?) throws {
        switch command {
        case .fullChargeOnce:
            state.session.fullChargeOnce = true
            state.session.calibration = nil
            appendEvent(PaprikaEvent(
                kind: .info,
                message: L.s("이번 한 번만 100% 까지 충전합니다.", "Charging to 100% once.")
            ))

        case .cancelFullChargeOnce:
            state.session.fullChargeOnce = false
            appendEvent(PaprikaEvent(
                kind: .info,
                message: L.s("100% 한 번 충전을 취소했습니다.", "Cancelled the one-off full charge.")
            ))

        case .startCalibration:
            guard let hardware, hardware.capabilities.isUsable else {
                throw PaprikaDaemonError.unsupported(L.s("충전 제어를 지원하지 않습니다.", "Charge control is unsupported."))
            }
            let now = Date()
            state.session.fullChargeOnce = false
            state.session.calibration = CalibrationState(
                phase: .discharge,
                startedAt: now,
                phaseStartedAt: now
            )
            appendEvent(PaprikaEvent(
                kind: .calibrationPhase,
                message: L.s(
                    "캘리브레이션을 시작합니다: \(state.config.calibrationFloor)% 까지 방전 → 100% 충전 → \(state.config.calibrationSettleMinutes)분 유지.",
                    "Calibration started: discharge to \(state.config.calibrationFloor)% → charge to 100% → hold \(state.config.calibrationSettleMinutes) min."
                )
            ))

        case .cancelCalibration:
            state.session.calibration = nil
            appendEvent(PaprikaEvent(
                kind: .info,
                message: L.s("캘리브레이션을 취소했습니다.", "Calibration cancelled.")
            ))

        case .pause:
            var minutes = 60
            if let payload, let request = try? PaprikaCoding.decode(PauseRequest.self, from: payload) {
                minutes = max(1, min(60 * 24, request.minutes))
            }
            state.session.pausedUntil = Date().addingTimeInterval(Double(minutes) * 60)
            if let hardware {
                _ = hardware.restoreDefaults()
            }
            appendEvent(PaprikaEvent(
                kind: .info,
                message: L.s("\(minutes)분간 충전 관리를 멈춥니다.", "Pausing charge management for \(minutes) min.")
            ))

        case .resume:
            state.session.pausedUntil = nil
            appendEvent(PaprikaEvent(
                kind: .info,
                message: L.s("충전 관리를 다시 시작합니다.", "Charge management resumed.")
            ))

        case .resetHardware:
            guard let hardware else {
                throw PaprikaDaemonError.unsupported(L.s("SMC 연결이 없습니다.", "No SMC connection."))
            }
            let failures = hardware.restoreDefaults()
            state.session.temperatureGuardActive = false
            state.session.lastAppliedAction = nil
            appendEvent(PaprikaEvent(
                kind: failures.isEmpty ? .info : .hardwareError,
                message: failures.isEmpty
                    ? L.s("SMC 를 기본 상태로 되돌렸습니다.", "SMC restored to defaults.")
                    : L.s("일부 복구 실패: \(failures.joined(separator: "; "))", "Partial restore failure: \(failures.joined(separator: "; "))")
            ))

        case .redetectHardware:
            smc?.closeConnection()
            smc = nil
            hardware = nil
            openHardware()
            appendEvent(PaprikaEvent(
                kind: .info,
                message: L.s("하드웨어 기능을 다시 탐지했습니다.", "Re-detected hardware capabilities.")
            ))

        case .forceTick:
            break  // tick 은 perform 이 알아서 호출한다

        case .clearEvents:
            events.removeAll()
        }
    }

    func dump(includeAllKeys: Bool, completion: @escaping (Result<SMCDump, Error>) -> Void) {
        queue.async { [self] in
            guard let hardware else {
                completion(.failure(PaprikaDaemonError.unsupported(L.s("SMC 연결이 없습니다.", "No SMC connection."))))
                return
            }
            completion(.success(hardware.dump(includeAllKeys: includeAllKeys)))
        }
    }
}

enum PaprikaDaemonError: Error, CustomStringConvertible {
    case noSnapshot
    case unsupported(String)
    case badPayload
    case shuttingDown

    var description: String {
        switch self {
        case .shuttingDown:
            return L.s("도우미가 종료 중입니다.", "The helper is shutting down.")
        case .noSnapshot:
            return L.s("아직 상태를 읽지 못했습니다.", "No snapshot available yet.")
        case .unsupported(let message):
            return message
        case .badPayload:
            return L.s("요청 데이터를 해석할 수 없습니다.", "Could not decode the request payload.")
        }
    }
}
