//
//  SettingsView.swift
//  Paprika
//

import AppKit
import PaprikaKit
import SwiftUI

struct SettingsView: View {
    // model 은 각 탭이 environmentObject 로 직접 받는다. 여기서는 쓰지 않는다.
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label(L.s("일반", "General"), systemImage: "gearshape") }

            ChargingSettingsTab()
                .tabItem { Label(L.s("충전", "Charging"), systemImage: "bolt") }

            BatteryInfoTab()
                .tabItem { Label(L.s("배터리", "Battery"), systemImage: "battery.100") }

            HistoryTab()
                .tabItem { Label(L.s("기록", "History"), systemImage: "chart.xyaxis.line") }

            AdvancedSettingsTab()
                .tabItem { Label(L.s("고급", "Advanced"), systemImage: "wrench.and.screwdriver") }

            AboutTab()
                .tabItem { Label(L.s("정보", "About"), systemImage: "info.circle") }
        }
        .frame(minWidth: 540, minHeight: 500)
        .padding(.top, 8)
    }
}

// MARK: - 일반

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        SettingsForm {
            SettingsSection {
                Toggle(isOn: $launchAtLogin) {
                    Text(L.s("로그인할 때 Paprika 실행", "Launch Paprika at login"))
                }
                .onChange(of: launchAtLogin) { newValue in
                    loginItemError = LoginItem.setEnabled(newValue)
                    // 실패하면 실제 상태로 되돌린다.
                    let actual = LoginItem.isEnabled
                    if actual != newValue { launchAtLogin = actual }
                }

                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(L.s(
                    "메뉴바 앱을 끄더라도 충전 제한은 도우미(paprikad)가 계속 유지합니다. 제한을 완전히 풀려면 '충전 관리 사용'을 끄세요.",
                    "Quitting the menu bar app does not lift the limit — the helper keeps enforcing it. Turn off “Manage charging” to lift it."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(L.s("시작", "Startup"))
            }

            SettingsSection {
                Picker(L.s("메뉴바 아이콘", "Menu bar icon"), selection: Binding(
                    get: { model.settings.iconStyle },
                    set: { model.settings.iconStyle = $0 }
                )) {
                    ForEach(MenuBarIconStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }

                Toggle(isOn: Binding(
                    get: { model.settings.showPercentage },
                    set: { model.settings.showPercentage = $0 }
                )) {
                    Text(L.s("메뉴바에 퍼센트 표시", "Show percentage in the menu bar"))
                }

                Toggle(isOn: Binding(
                    get: { model.settings.showLimitBadge },
                    set: { model.settings.showLimitBadge = $0 }
                )) {
                    Text(L.s("상한도 함께 표시 (예: 78% →80)", "Also show the limit (e.g. 78% →80)"))
                }

                LabeledStepper(
                    title: L.s("빨간 파프리카가 되는 잔량", "Low battery threshold"),
                    value: Binding(
                        get: { model.settings.lowBatteryThreshold },
                        set: { model.settings.lowBatteryThreshold = $0 }
                    ),
                    range: 5...40,
                    step: 5,
                    format: { Fmt.percent($0) }
                )
            } header: {
                Text(L.s("모양", "Appearance"))
            }

            SettingsSection {
                Picker(L.s("언어", "Language"), selection: Binding(
                    get: { model.settings.language },
                    set: { model.settings.language = $0 }
                )) {
                    ForEach(PaprikaLanguage.allCases, id: \.self) { language in
                        Text(language.label).tag(language)
                    }
                }
                Text(L.s(
                    "이미 그려진 화면은 다음에 열 때 새 언어로 바뀝니다.",
                    "Already-drawn windows switch language next time they open."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                Toggle(isOn: Binding(
                    get: { model.settings.notificationsEnabled },
                    set: { model.settings.notificationsEnabled = $0 }
                )) {
                    Text(L.s("상태가 바뀌면 알림 보내기", "Notify me when the state changes"))
                }

                LabeledStepper(
                    title: L.s("상태 갱신 주기", "Refresh interval"),
                    value: Binding(
                        get: { model.settings.refreshInterval },
                        set: {
                            model.settings.refreshInterval = $0
                            model.restartPollTimer()
                        }
                    ),
                    range: 1...30,
                    step: 1,
                    format: { String(format: "%.0f\(L.s("초", " s"))", $0) }
                )
            } header: {
                Text(L.s("동작", "Behaviour"))
            }
        }
    }
}

// MARK: - 충전

private struct ChargingSettingsTab: View {
    @EnvironmentObject private var model: AppModel

    private var capabilities: HardwareCapabilities? { model.snapshot?.capabilities }

    var body: some View {
        SettingsForm {
            SettingsSection {
                LabeledStepper(
                    title: L.s("충전 상한", "Charge limit"),
                    value: Binding(
                        get: { Double(model.draftConfig.limit) },
                        set: {
                            model.draftConfig.limit = Int($0)
                            model.configDidChangeLocally()
                        }
                    ),
                    range: 20...100,
                    step: 1,
                    format: { Fmt.percent($0) }
                )

                LabeledStepper(
                    title: L.s("히스테리시스 (재충전 여유)", "Hysteresis (resume margin)"),
                    value: Binding(
                        get: { Double(model.draftConfig.sail) },
                        set: {
                            model.draftConfig.sail = Int($0)
                            model.configDidChangeLocally()
                        }
                    ),
                    range: 0...30,
                    step: 1,
                    format: { Fmt.percent($0) }
                )

                Text(L.s(
                    "상한에 도달한 뒤 \(model.draftConfig.resumeThreshold)% 아래로 내려가야 다시 충전합니다. 값이 클수록 충전 사이클을 아끼지만, 배터리 잔량 변동 폭은 커집니다.",
                    "After hitting the limit, charging resumes only below \(model.draftConfig.resumeThreshold)%. Larger values save charge cycles but let the level swing more."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(L.s("상한", "Limit"))
            }

            SettingsSection {
                if capabilities?.supportsAdapterControl == true {
                    Toggle(isOn: binding(\.allowForcedDischarge)) {
                        Text(L.s("상한보다 높으면 어댑터를 끊어 방전", "Discharge by cutting the adapter when above the limit"))
                    }
                    LabeledStepper(
                        title: L.s("방전을 시작하는 여유", "Discharge tolerance"),
                        value: Binding(
                            get: { Double(model.draftConfig.dischargeTolerance) },
                            set: {
                                model.draftConfig.dischargeTolerance = Int($0)
                                model.configDidChangeLocally()
                            }
                        ),
                        range: 0...20,
                        step: 1,
                        format: { Fmt.percent($0) }
                    )
                    .disabled(!model.draftConfig.allowForcedDischarge)

                    Text(L.s(
                        "상한 + 여유값을 넘어야 방전을 시작합니다. 여유가 0 이면 조금만 넘어도 바로 방전해서 배터리를 더 자주 쓰게 됩니다.",
                        "Discharging starts only above limit + tolerance. With 0 it reacts to tiny overshoots and uses the battery more often."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(L.s(
                        "이 맥에서는 어댑터 차단 키(CH0I/CH0J/CHIE)를 찾지 못해 강제 방전을 쓸 수 없습니다.",
                        "No adapter-control key (CH0I/CH0J/CHIE) on this Mac, so forced discharge is unavailable."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text(L.s("강제 방전", "Forced discharge"))
            }

            SettingsSection {
                Toggle(isOn: binding(\.temperatureGuardEnabled)) {
                    Text(L.s("배터리가 뜨거우면 충전 멈추기", "Pause charging when the battery is hot"))
                }
                LabeledStepper(
                    title: L.s("온도 한계", "Temperature limit"),
                    value: Binding(
                        get: { model.draftConfig.temperatureLimit },
                        set: {
                            model.draftConfig.temperatureLimit = $0
                            model.configDidChangeLocally()
                        }
                    ),
                    range: 25...55,
                    step: 1,
                    format: { Fmt.celsius($0) }
                )
                .disabled(!model.draftConfig.temperatureGuardEnabled)

                if capabilities?.supportsFineGrainedControl == false {
                    Text(L.s(
                        "지금은 펌웨어 위임 방식으로 제어하고 있어서 온도 보호가 동작하지 않습니다.",
                        "Charging is delegated to firmware right now, so the temperature guard has no effect."
                    ))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text(L.s("온도 보호", "Temperature guard"))
            }

            SettingsSection {
                CalibrationControls()
            } header: {
                Text(L.s("캘리브레이션", "Calibration"))
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<PaprikaConfig, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.draftConfig[keyPath: keyPath] },
            set: { newValue in
                model.draftConfig[keyPath: keyPath] = newValue
                model.applyConfigNow()
            }
        )
    }
}

private struct CalibrationControls: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let calibration = model.snapshot?.session.calibration {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(calibration.phase.label)
                        .font(.callout)
                    Spacer()
                    Button(L.s("중지", "Stop")) { model.run(.cancelCalibration) }
                }
                Text(L.s(
                    "\(Fmt.relativeTime(calibration.startedAt)) 시작",
                    "started \(Fmt.relativeTime(calibration.startedAt))"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text(L.s(
                        "\(model.draftConfig.calibrationFloor)% 까지 방전 → 100% 충전 → \(model.draftConfig.calibrationSettleMinutes)분 유지",
                        "Discharge to \(model.draftConfig.calibrationFloor)% → charge to 100% → hold \(model.draftConfig.calibrationSettleMinutes) min"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L.s("시작", "Start")) { model.run(.startCalibration) }
                        .disabled(!model.canControlCharging)
                }

                LabeledStepper(
                    title: L.s("방전 하한", "Discharge floor"),
                    value: Binding(
                        get: { Double(model.draftConfig.calibrationFloor) },
                        set: {
                            model.draftConfig.calibrationFloor = Int($0)
                            model.configDidChangeLocally()
                        }
                    ),
                    range: 3...30,
                    step: 1,
                    format: { Fmt.percent($0) }
                )

                LabeledStepper(
                    title: L.s("100% 유지 시간", "Hold at 100%"),
                    value: Binding(
                        get: { Double(model.draftConfig.calibrationSettleMinutes) },
                        set: {
                            model.draftConfig.calibrationSettleMinutes = Int($0)
                            model.configDidChangeLocally()
                        }
                    ),
                    range: 0...360,
                    step: 15,
                    format: { String(format: "%.0f\(L.s("분", " min"))", $0) }
                )
            }

            Text(L.s(
                "캘리브레이션은 배터리 게이지의 오차를 줄이는 작업입니다. 배터리에 부담이 가므로 몇 달에 한 번 정도로 충분합니다.",
                "Calibration re-aligns the battery gauge. It stresses the cell, so a few times a year is plenty."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 배터리 정보

private struct BatteryInfoTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsForm {
            if let battery = model.battery {
                SettingsSection {
                    InfoRow(L.s("현재 잔량", "Current charge"), Fmt.percent(model.displayPercent, decimals: 1))
                    InfoRow(L.s("사이클 수", "Cycle count"), battery.cycleCount > 0 ? "\(battery.cycleCount)" : "–")
                    InfoRow(
                        L.s("건강도", "Health"),
                        battery.healthPercent.map { Fmt.percent($0, decimals: 1) } ?? "–"
                    )
                    InfoRow(L.s("설계 용량", "Design capacity"), Fmt.mAh(battery.designCapacity))
                    InfoRow(L.s("현재 최대 용량", "Full charge capacity"), Fmt.mAh(battery.nominalCapacity))
                    InfoRow(L.s("현재 용량", "Remaining capacity"), Fmt.mAh(battery.rawCurrentCapacity))
                    if let serial = battery.serialNumber, !serial.isEmpty {
                        InfoRow(L.s("시리얼", "Serial"), serial)
                    }
                } header: {
                    Text(L.s("배터리", "Battery"))
                }

                SettingsSection {
                    InfoRow(L.s("온도", "Temperature"), Fmt.celsius(battery.temperature))
                    InfoRow(L.s("전압", "Voltage"), Fmt.volts(battery.voltage))
                    InfoRow(L.s("전류", "Current"), Fmt.amps(battery.amperage))
                    InfoRow(L.s("배터리 전력", "Battery power"), Fmt.signedWatts(battery.batteryWatts ?? model.snapshot?.telemetry.batteryWatts))
                    if let telemetry = model.snapshot?.telemetry {
                        InfoRow(L.s("어댑터 입력", "Adapter input"), Fmt.watts(telemetry.adapterWatts))
                        InfoRow(L.s("어댑터 전압", "Adapter voltage"), Fmt.volts(telemetry.adapterVolts))
                        InfoRow(L.s("어댑터 전류", "Adapter current"), Fmt.amps(telemetry.adapterAmps))
                    }
                    InfoRow(
                        L.s("어댑터", "Adapter"),
                        battery.isPluggedIn
                            ? [battery.adapterWatts.map { "\($0)W" }, battery.adapterName]
                                .compactMap { $0 }
                                .joined(separator: " · ")
                            : L.s("연결 안 됨", "Not connected")
                    )
                    InfoRow(L.s("완충까지", "Time to full"), Fmt.duration(minutes: battery.minutesToFull))
                    InfoRow(L.s("사용 가능 시간", "Time to empty"), Fmt.duration(minutes: battery.minutesToEmpty))
                } header: {
                    Text(L.s("전력", "Power"))
                }
            } else {
                Text(L.s("배터리 정보를 읽을 수 없습니다.", "Cannot read battery information."))
            }

            if let snapshot = model.snapshot {
                SettingsSection {
                    InfoRow(L.s("제어 방식", "Control backend"), snapshot.capabilities.backend.label)
                    InfoRow(
                        L.s("어댑터 제어 키", "Adapter key"),
                        snapshot.capabilities.adapterKey == .none
                            ? L.s("없음", "none")
                            : snapshot.capabilities.adapterKey.rawValue
                    )
                    InfoRow(
                        L.s("하드웨어 충전 허용", "Hardware allows charging"),
                        snapshot.hardwareChargingAllowed ? L.s("예", "yes") : L.s("아니오", "no")
                    )
                    InfoRow(
                        L.s("하드웨어 어댑터 사용", "Hardware adapter enabled"),
                        snapshot.hardwareAdapterEnabled ? L.s("예", "yes") : L.s("아니오", "no")
                    )
                    if let firmwareLimit = snapshot.firmwareLimit {
                        InfoRow(
                            L.s("펌웨어 제한", "Firmware limit"),
                            firmwareLimit.active
                                ? "\(firmwareLimit.lower)–\(firmwareLimit.upper)%"
                                : L.s("비활성", "inactive")
                        )
                    }
                } header: {
                    Text(L.s("하드웨어", "Hardware"))
                }
            }
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}

// MARK: - 공통 폼 조각

/// macOS 13 의 Form 스타일 차이를 흡수하는 간단한 래퍼.
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Form 안의 한 묶음. 제목 + 내용.
/// (SwiftUI 의 Section 을 가리지 않도록 이름을 달리 했다)
struct SettingsSection<Content: View, Header: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var header: Header

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// 값 + 슬라이더 + 스테퍼를 한 줄로.
struct LabeledStepper: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Stepper(value: $value, in: range, step: step) {
                    EmptyView()
                }
                .labelsHidden()
            }
            Slider(value: $value, in: range, step: step)
        }
        .font(.callout)
    }
}
