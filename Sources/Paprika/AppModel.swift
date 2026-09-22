//
//  AppModel.swift
//  Paprika
//
//  UI 의 단일 진실 공급원.
//
//  역할
//  ----
//  * 데몬에서 주기적으로 스냅샷을 받아온다.
//  * 사용자가 만지는 설정(draftConfig)을 들고 있다가 디바운스해서 데몬에 보낸다.
//  * 히스토리를 적립하고, 알림을 내보낸다.
//  * 데몬이 없을 때도 배터리 정보만은 직접 읽어서 최소한의 UI 를 유지한다.
//

import AppKit
import Combine
import Foundation
import PaprikaKit
import SwiftUI

/// 주의: 이 클래스는 **메인 스레드 전용**이다.
/// 모든 접근 경로가 메인이다 — SwiftUI 뷰, 메인 런루프 타이머,
/// 그리고 HelperConnection(completionQueue: .main) 의 콜백.
/// @MainActor 를 붙이지 않은 이유는 Swift 5 언어 모드에서 콜백 클로저의 격리
/// 추론과 얽혀 컴파일이 까다로워지기 때문이다.
final class AppModel: ObservableObject {

    static let shared = AppModel()

    // MARK: 게시되는 상태

    @Published private(set) var snapshot: PaprikaSnapshot?
    @Published private(set) var helperState: HelperState = .unknown
    /// 데몬이 없을 때 쓰는 폴백. 배터리 정보만 들어 있다.
    @Published private(set) var fallbackBattery: BatteryInfo?
    /// 슬라이더/토글이 직접 묶이는 편집용 설정.
    @Published var draftConfig = PaprikaConfig()
    @Published private(set) var isApplyingConfig = false
    @Published private(set) var lastActionError: String?
    @Published private(set) var history: [HistorySample] = []
    @Published private(set) var smcDump: SMCDump?
    @Published private(set) var isLoadingDump = false

    let settings = UserSettings()

    // MARK: 내부

    private let helper = HelperConnection()
    private let batteryReader = BatteryReader()
    private let historyStore = HistoryStore()
    private let notifier = Notifier()

    private var pollTimer: Timer?
    private var configPushWorkItem: DispatchWorkItem?
    /// 사용자가 방금 설정을 만졌으면, 스냅샷이 draftConfig 를 덮어쓰지 않게 한다.
    private var lastLocalEditAt: Date?
    private let localEditGracePeriod: TimeInterval = 2.0
    private var lastHistorySampleAt: Date?
    private var hasSeenFirstSnapshot = false
    private var lastPrunedAt: Date?
    private var cancellables = Set<AnyCancellable>()
    /// 메뉴바 아이콘 캐시. 값이 안 바뀌면 같은 NSImage 를 재사용한다.
    private var cachedIcon: (key: String, image: NSImage)?

    private init() {
        L.language = settings.language
        fallbackBattery = batteryReader.read()

        // UserSettings 는 별도의 ObservableObject 다. 그대로 두면 아이콘 스타일을
        // 바꿔도 메뉴바가 갱신되지 않으므로, 변경을 이쪽으로 흘려보낸다.
        settings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        helper.onConnectionLost = { [weak self] in
            guard let self else { return }
            PaprikaLog.app.notice("도우미 연결이 끊겼습니다 — 다시 확인합니다.")
            self.refreshHelperState()
        }
    }

    // MARK: - 수명 주기

    func start() {
        notifier.requestAuthorizationIfNeeded()
        refreshHelperState()
        reloadHistory()
        restartPollTimer()
        refresh()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        helper.invalidate()
    }

    func restartPollTimer() {
        pollTimer?.invalidate()
        let timer = Timer.scheduledTimer(
            withTimeInterval: settings.refreshInterval,
            repeats: true
        ) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // MARK: - 폴링

    func refresh() {
        // 데몬이 없으면 배터리만 직접 읽는다.
        guard HelperConnection.isHelperInstalled else {
            fallbackBattery = batteryReader.read()
            if helperState != .notInstalled { helperState = .notInstalled }
            return
        }

        helper.fetchSnapshot { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let snapshot):
                self.apply(snapshot: snapshot)
            case .failure(let error):
                self.fallbackBattery = self.batteryReader.read()
                self.handle(connectionError: error)
            }
        }
    }

    private func apply(snapshot incoming: PaprikaSnapshot) {
        snapshot = incoming
        fallbackBattery = incoming.battery

        if case .ready = helperState {
            // 이미 ready — 버전 정보를 유지한다.
        } else {
            helperState = .ready(
                version: incoming.helperVersion,
                protocolVersion: PaprikaIPC.protocolVersion
            )
        }

        // 사용자가 방금 만진 값을 스냅샷이 되돌려버리지 않게 한다.
        let isEditing = lastLocalEditAt.map { Date().timeIntervalSince($0) < localEditGracePeriod } ?? false
        if !isEditing, configPushWorkItem == nil, draftConfig != incoming.config {
            draftConfig = incoming.config
        }

        notifier.process(
            events: incoming.recentEvents,
            enabled: settings.notificationsEnabled,
            markOnly: !hasSeenFirstSnapshot
        )
        hasSeenFirstSnapshot = true

        recordHistoryIfDue(from: incoming)
        pruneHistoryIfDue()
    }

    private func handle(connectionError error: Error) {
        if let clientError = error as? HelperClientError {
            switch clientError {
            case .notInstalled:
                helperState = .notInstalled
            case .timeout, .connectionFailed:
                helperState = .unreachable(clientError.localizedDescription)
            case .remote(let message):
                lastActionError = message
            case .decoding(let detail):
                helperState = .unreachable(detail)
            }
        } else {
            helperState = .unreachable(error.localizedDescription)
        }
    }

    func refreshHelperState() {
        helper.handshake { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let state):
                self.helperState = state
                if state.isReady { self.refresh() }
            case .failure(let error):
                self.helperState = .unreachable(error.localizedDescription)
            }
        }
    }

    // MARK: - 설정 변경

    /// 슬라이더를 움직이는 동안 XPC 를 폭격하지 않도록 0.4초 디바운스한다.
    func configDidChangeLocally() {
        lastLocalEditAt = Date()
        configPushWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.pushConfig()
        }
        configPushWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    /// 디바운스 없이 즉시 반영한다(토글 등).
    func applyConfigNow() {
        lastLocalEditAt = Date()
        configPushWorkItem?.cancel()
        configPushWorkItem = nil
        pushConfig()
    }

    private func pushConfig() {
        configPushWorkItem = nil
        guard HelperConnection.isHelperInstalled else { return }

        isApplyingConfig = true
        let outgoing = draftConfig.sanitized()
        helper.update(config: outgoing) { [weak self] result in
            guard let self else { return }
            self.isApplyingConfig = false
            switch result {
            case .success(let snapshot):
                self.lastActionError = nil
                self.apply(snapshot: snapshot)
            case .failure(let error):
                self.lastActionError = error.localizedDescription
                self.handle(connectionError: error)
            }
        }
    }

    // MARK: - 명령

    func run(_ command: PaprikaCommand, payload: Data? = nil) {
        guard HelperConnection.isHelperInstalled else {
            lastActionError = HelperClientError.notInstalled.localizedDescription
            return
        }
        helper.perform(command, payload: payload) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let snapshot):
                self.lastActionError = nil
                self.apply(snapshot: snapshot)
            case .failure(let error):
                self.lastActionError = error.localizedDescription
            }
        }
    }

    func pauseManagement(minutes: Int) {
        let payload = try? PaprikaCoding.encode(PauseRequest(minutes: minutes))
        run(.pause, payload: payload)
    }

    func loadSMCDump(includeAllKeys: Bool) {
        isLoadingDump = true
        helper.smcDump(includeAllKeys: includeAllKeys) { [weak self] result in
            guard let self else { return }
            self.isLoadingDump = false
            switch result {
            case .success(let dump):
                self.smcDump = dump
                self.lastActionError = nil
            case .failure(let error):
                self.lastActionError = error.localizedDescription
            }
        }
    }

    func clearActionError() {
        lastActionError = nil
    }

    // MARK: - 히스토리

    private func recordHistoryIfDue(from snapshot: PaprikaSnapshot) {
        let now = Date()
        if let last = lastHistorySampleAt, now.timeIntervalSince(last) < settings.historySampleSeconds {
            return
        }
        lastHistorySampleAt = now

        let sample = HistorySample(
            date: now,
            percent: snapshot.displayPercent,
            isCharging: snapshot.battery.isCharging,
            isPluggedIn: snapshot.battery.isPluggedIn,
            limit: snapshot.config.limit,
            temperature: snapshot.battery.temperature,
            batteryWatts: snapshot.battery.batteryWatts ?? snapshot.telemetry.batteryWatts
        )
        historyStore.append(sample)
        history.append(sample)

        // 메모리에 들고 있는 양도 제한한다.
        let cutoff = now.addingTimeInterval(-Double(settings.historyRetentionDays) * 86_400)
        if (history.first?.date ?? now) < cutoff {
            history = history.filter { $0.date >= cutoff }
        }
    }

    private func pruneHistoryIfDue() {
        let now = Date()
        if let last = lastPrunedAt, now.timeIntervalSince(last) < 3600 { return }
        lastPrunedAt = now
        historyStore.prune(retentionDays: settings.historyRetentionDays)
    }

    func reloadHistory() {
        historyStore.load(days: settings.historyRetentionDays) { [weak self] samples in
            self?.history = samples
        }
    }

    func deleteHistory() {
        historyStore.deleteAll { [weak self] in
            self?.history = []
        }
    }

    var historyFileSizeDescription: String {
        let bytes = historyStore.fileSizeBytes
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: - 표시용 계산값

    var visualState: PepperVisualState {
        guard helperState.isReady || snapshot != nil else {
            // 데몬이 없어도 배터리 상태 정도는 보여준다.
            guard let battery = fallbackBattery else { return .disconnected }
            if battery.isCharging { return .charging }
            if !battery.isPluggedIn {
                return battery.percent <= settings.lowBatteryThreshold ? .low : .onBattery
            }
            return .unmanaged
        }
        return PepperVisualState.from(
            snapshot: snapshot,
            lowThreshold: settings.lowBatteryThreshold
        )
    }

    var displayPercent: Double {
        snapshot?.displayPercent ?? fallbackBattery?.percent ?? 0
    }

    var battery: BatteryInfo? {
        snapshot?.battery ?? fallbackBattery
    }

    var menuBarIcon: NSImage {
        // 1% 단위로만 다시 그린다. 매 폴링마다 새 NSImage 를 만들면 메뉴바가
        // 불필요하게 다시 레이아웃된다.
        let rounded = Int(displayPercent.rounded())
        let state = visualState
        let key = "\(rounded)|\(state)|\(settings.iconStyle.rawValue)"
        if let cachedIcon, cachedIcon.key == key { return cachedIcon.image }

        let image = PepperIconRenderer.image(
            fraction: Double(rounded) / 100,
            state: state,
            style: settings.iconStyle
        )
        cachedIcon = (key, image)
        return image
    }

    var menuBarText: String? {
        var parts: [String] = []
        if settings.showPercentage || settings.iconStyle == .textOnly {
            parts.append("\(Int(displayPercent.rounded()))%")
        }
        if settings.showLimitBadge, let limit = snapshot?.decision.effectiveTarget {
            parts.append("→\(limit)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// 메뉴 맨 위에 보여줄 한 줄 상태 설명.
    var statusHeadline: String {
        if case .notInstalled = helperState {
            return L.s("권한 도우미를 설치해야 합니다", "Privileged helper not installed")
        }
        if case .unreachable = helperState {
            return L.s("도우미와 통신할 수 없습니다", "Cannot reach the helper")
        }
        guard let snapshot else { return L.s("상태를 읽는 중…", "Reading status…") }
        return snapshot.decision.reason.label
    }

    var statusDetail: String? {
        snapshot?.decision.detail
    }

    /// 데몬이 보고한 오류 또는 앱에서 생긴 오류.
    var problemMessage: String? {
        if let lastActionError { return lastActionError }
        if let error = snapshot?.lastError { return error }
        if case .unreachable(let detail) = helperState { return detail }
        if helperState.hasVersionMismatch {
            return L.s(
                "앱과 도우미의 버전이 다릅니다. Scripts/install-helper.sh 를 다시 실행해 주세요.",
                "App and helper versions differ. Re-run Scripts/install-helper.sh."
            )
        }
        return nil
    }

    var canControlCharging: Bool {
        snapshot?.capabilities.isUsable ?? false
    }
}
