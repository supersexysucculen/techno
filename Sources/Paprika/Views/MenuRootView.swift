//
//  MenuRootView.swift
//  Paprika
//
//  메뉴바를 눌렀을 때 뜨는 패널.
//  MenuBarExtra(.window) 스타일이라 슬라이더 같은 조작도 넣을 수 있다.
//

import AppKit
import PaprikaKit
import SwiftUI

struct MenuRootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BatteryHeaderView()

            if case .notInstalled = model.helperState {
                HelperSetupCard()
            } else {
                if let problem = model.problemMessage {
                    ProblemBanner(message: problem)
                }
                if model.snapshot?.capabilities.isUsable == false {
                    UnsupportedCard()
                } else {
                    ChargeLimitSection()
                    Divider()
                    QuickActionsSection()
                    Divider()
                    BatteryFactsSection()
                }
            }

            Divider()
            FooterSection()
        }
        .padding(14)
        .frame(width: 330)
    }
}

// MARK: - 충전 상한

private struct ChargeLimitSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L.s("충전 상한", "Charge limit"))
                    .font(.headline)
                Spacer()
                Text("\(model.draftConfig.limit)%")
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(model.draftConfig.managementEnabled ? .primary : .secondary)
            }

            Slider(
                value: Binding(
                    get: { Double(model.draftConfig.limit) },
                    set: { newValue in
                        let rounded = Int(newValue.rounded())
                        guard rounded != model.draftConfig.limit else { return }
                        model.draftConfig.limit = rounded
                        model.configDidChangeLocally()
                    }
                ),
                in: 20...100,
                step: 1
            )
            .disabled(!model.draftConfig.managementEnabled)

            HStack(spacing: 6) {
                ForEach([60, 70, 80, 90, 100], id: \.self) { preset in
                    Button("\(preset)") {
                        model.draftConfig.limit = preset
                        model.applyConfigNow()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!model.draftConfig.managementEnabled)
                }
                Spacer()
            }

            Toggle(
                isOn: Binding(
                    get: { model.draftConfig.managementEnabled },
                    set: { newValue in
                        model.draftConfig.managementEnabled = newValue
                        model.applyConfigNow()
                    }
                )
            ) {
                Text(L.s("충전 관리 사용", "Manage charging"))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if model.draftConfig.managementEnabled, model.draftConfig.sail > 0 {
                Text(L.s(
                    "\(model.draftConfig.resumeThreshold)% 아래로 떨어질 때까지 다시 충전하지 않습니다.",
                    "Will not resume charging until it drops below \(model.draftConfig.resumeThreshold)%."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 빠른 동작

private struct QuickActionsSection: View {
    @EnvironmentObject private var model: AppModel

    private var session: SessionState? { model.snapshot?.session }
    private var capabilities: HardwareCapabilities? { model.snapshot?.capabilities }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.s("빠른 동작", "Quick actions"))
                .font(.headline)

            // 100% 한 번만 충전
            if session?.fullChargeOnce == true {
                ActionRow(
                    symbol: "bolt.badge.clock.fill",
                    title: L.s("100% 충전 예약됨 — 취소", "Full charge queued — cancel"),
                    tint: .orange
                ) {
                    model.run(.cancelFullChargeOnce)
                }
            } else {
                ActionRow(
                    symbol: "bolt.badge.clock",
                    title: L.s("이번 한 번만 100% 까지 충전", "Charge to 100% just this once")
                ) {
                    model.run(.fullChargeOnce)
                }
                .disabled(!model.draftConfig.managementEnabled)
            }

            // 일시 중지 / 재개
            if let pausedUntil = session?.pausedUntil, pausedUntil > Date() {
                ActionRow(
                    symbol: "play.circle",
                    title: L.s("일시 중지 해제 (\(Fmt.relativeTime(pausedUntil)) 까지)", "Resume (paused until \(Fmt.clockTime(pausedUntil)))"),
                    tint: .orange
                ) {
                    model.run(.resume)
                }
            } else {
                Menu {
                    ForEach([30, 60, 120, 240, 480], id: \.self) { minutes in
                        Button(Fmt.duration(minutes: minutes)) {
                            model.pauseManagement(minutes: minutes)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "pause.circle")
                            .frame(width: 16)
                        Text(L.s("잠시 관리 멈추기", "Pause management"))
                        Spacer()
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: false, vertical: true)
            }

            // 강제 방전 토글
            if capabilities?.supportsAdapterControl == true, capabilities?.supportsFineGrainedControl == true {
                Toggle(
                    isOn: Binding(
                        get: { model.draftConfig.allowForcedDischarge },
                        set: { newValue in
                            model.draftConfig.allowForcedDischarge = newValue
                            model.applyConfigNow()
                        }
                    )
                ) {
                    Text(L.s("상한보다 높으면 방전해서 내리기", "Discharge down to the limit"))
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
            }

            // 캘리브레이션
            if let calibration = session?.calibration {
                ActionRow(
                    symbol: "xmark.circle",
                    title: L.s("캘리브레이션 중지 (\(calibration.phase.label))", "Stop calibration (\(calibration.phase.label))"),
                    tint: .orange
                ) {
                    model.run(.cancelCalibration)
                }
            }
        }
    }
}

private struct ActionRow: View {
    let symbol: String
    let title: String
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(title)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 배터리 정보

private struct BatteryFactsSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let battery = model.battery {
                FactRow(
                    label: L.s("사이클", "Cycles"),
                    value: battery.cycleCount > 0 ? "\(battery.cycleCount)" : "–"
                )
                FactRow(
                    label: L.s("건강도", "Health"),
                    value: battery.healthPercent.map { Fmt.percent($0, decimals: 1) } ?? "–"
                )
                FactRow(
                    label: L.s("온도", "Temperature"),
                    value: Fmt.celsius(battery.temperature)
                )
                FactRow(
                    label: L.s("전력", "Power"),
                    value: powerText(battery)
                )
                if battery.isPluggedIn {
                    FactRow(
                        label: L.s("어댑터", "Adapter"),
                        value: adapterText(battery)
                    )
                }
            }
            if let backend = model.snapshot?.capabilities.backend {
                FactRow(label: L.s("제어 방식", "Control"), value: backend.label, isSubtle: true)
            }
        }
    }

    private func powerText(_ battery: BatteryInfo) -> String {
        let watts = battery.batteryWatts ?? model.snapshot?.telemetry.batteryWatts
        guard let watts else { return "–" }
        let direction = watts > 0.05
            ? L.s("충전", "in")
            : (watts < -0.05 ? L.s("방전", "out") : L.s("정지", "idle"))
        return "\(Fmt.signedWatts(watts)) (\(direction))"
    }

    private func adapterText(_ battery: BatteryInfo) -> String {
        var parts: [String] = []
        if let watts = battery.adapterWatts, watts > 0 { parts.append("\(watts)W") }
        if let input = model.snapshot?.telemetry.adapterWatts { parts.append(Fmt.watts(input)) }
        if let name = battery.adapterName, !name.isEmpty { parts.append(name) }
        if model.snapshot?.hardwareAdapterEnabled == false {
            parts.append(L.s("차단됨", "blocked"))
        }
        return parts.isEmpty ? L.s("연결됨", "connected") : parts.joined(separator: " · ")
    }
}

private struct FactRow: View {
    let label: String
    let value: String
    var isSubtle: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(isSubtle ? .secondary : .primary)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - 하단

private struct FooterSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Button {
                SettingsWindowController.shared.show(model: model)
            } label: {
                Label(L.s("설정…", "Settings…"), systemImage: "gearshape")
            }
            .buttonStyle(.plain)

            Spacer()

            if model.isApplyingConfig {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label(L.s("종료", "Quit"), systemImage: "power")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
        .font(.callout)
    }
}

// MARK: - 카드들

private struct ProblemBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct UnsupportedCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L.s("충전 제어를 사용할 수 없습니다", "Charge control unavailable"), systemImage: "xmark.octagon")
                .font(.headline)
            Text(L.s(
                "이 맥의 SMC 에서 충전 제어에 쓸 수 있는 키를 찾지 못했습니다. 설정 → 고급 → SMC 진단에서 어떤 키가 보이는지 확인해 보세요.",
                "No usable charge-control SMC keys were found on this Mac. Check Settings → Advanced → SMC diagnostics."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Button(L.s("다시 탐지", "Re-detect")) {
                model.run(.redetectHardware)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 데몬이 아직 설치되지 않았을 때 보여주는 안내.
struct HelperSetupCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var didCopy = false

    private var command: String {
        "sudo \(installScriptPath)"
    }

    private var installScriptPath: String {
        // 앱 번들 안에 설치 스크립트를 함께 넣어두므로 경로를 그대로 안내할 수 있다.
        if let resource = Bundle.main.resourcePath {
            let candidate = resource + "/install-helper.sh"
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return "./Scripts/install-helper.sh"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L.s("한 번만 설치가 필요합니다", "One-time setup required"), systemImage: "lock.shield")
                .font(.headline)

            Text(L.s(
                "충전을 제어하려면 root 권한으로 동작하는 작은 도우미(paprikad)가 필요합니다. 터미널에서 아래 명령을 한 번 실행해 주세요.",
                "Controlling charging needs a small root helper (paprikad). Run this once in Terminal."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Button(didCopy ? L.s("복사했습니다", "Copied") : L.s("명령 복사", "Copy command")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    didCopy = true
                }
                .controlSize(.small)

                Button(L.s("다시 확인", "Check again")) {
                    model.refreshHelperState()
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}
