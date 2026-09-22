//
//  AdvancedTab.swift
//  Paprika
//
//  문제가 생겼을 때 실제로 도움이 되는 화면.
//  SMC 키가 보이는지, 어떤 방식으로 제어하는지, 이벤트 로그가 무엇인지를 보여준다.
//

import AppKit
import PaprikaKit
import SwiftUI

struct AdvancedSettingsTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var includeAllKeys = false
    @State private var showResetConfirm = false
    @State private var copyFeedback: String?

    var body: some View {
        SettingsForm {
            SettingsSection {
                HStack {
                    Text(L.s("도우미 상태", "Helper status"))
                    Spacer()
                    Text(helperStatusText)
                        .foregroundStyle(helperStatusColor)
                }
                if let snapshot = model.snapshot {
                    HStack {
                        Text(L.s("데몬 가동 시간", "Daemon uptime"))
                        Spacer()
                        Text(Fmt.uptime(since: snapshot.daemonStartedAt))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    HStack {
                        Text(L.s("마지막 갱신", "Last update"))
                        Spacer()
                        Text(Fmt.clockTime(snapshot.generatedAt))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                HStack {
                    Button(L.s("연결 다시 확인", "Re-check connection")) {
                        model.refreshHelperState()
                    }
                    Button(L.s("하드웨어 다시 탐지", "Re-detect hardware")) {
                        model.run(.redetectHardware)
                    }
                }
            } header: {
                Text(L.s("권한 도우미", "Privileged helper"))
            }

            SettingsSection {
                Picker(L.s("제어 방식", "Control backend"), selection: Binding(
                    get: { model.draftConfig.forcedBackend ?? .unsupported },
                    set: { newValue in
                        model.draftConfig.forcedBackend = (newValue == .unsupported) ? nil : newValue
                        model.applyConfigNow()
                    }
                )) {
                    Text(L.s("자동 (권장)", "Automatic (recommended)")).tag(ChargeControlBackend.unsupported)
                    Text("CH0B / CH0C").tag(ChargeControlBackend.classicLegacy)
                    Text("CHTE").tag(ChargeControlBackend.tahoeLegacy)
                    Text("bfF0 / bfD0 / bfE0").tag(ChargeControlBackend.firmware)
                }
                Text(L.s(
                    "선택한 방식을 이 맥에서 쓸 수 없으면 자동 탐지 결과가 그대로 유지됩니다.",
                    "If the chosen backend is unavailable on this Mac, auto-detection stays in effect."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                LabeledStepper(
                    title: L.s("제어 루프 주기", "Control loop interval"),
                    value: Binding(
                        get: { model.draftConfig.pollInterval },
                        set: {
                            model.draftConfig.pollInterval = $0
                            model.configDidChangeLocally()
                        }
                    ),
                    range: 2...60,
                    step: 1,
                    format: { String(format: "%.0f\(L.s("초", " s"))", $0) }
                )

                if model.snapshot?.capabilities.hasMagSafeLED == true {
                    Toggle(isOn: Binding(
                        get: { model.draftConfig.controlMagSafeLED },
                        set: {
                            model.draftConfig.controlMagSafeLED = $0
                            model.applyConfigNow()
                        }
                    )) {
                        Text(L.s("MagSafe LED 색을 상태에 맞춰 바꾸기 (실험적)", "Tint the MagSafe LED to match the state (experimental)"))
                    }
                    if let led = model.snapshot?.magSafeLED {
                        HStack {
                            Text(L.s("현재 LED", "Current LED"))
                            Spacer()
                            Text(led.label).foregroundStyle(.secondary)
                        }
                    }
                }

                Text(L.s(
                    "도우미가 종료될 때(수동 정지·언인스톨·재부팅 포함) SMC 는 항상 기본 상태로 되돌아갑니다. 이건 끌 수 없게 해두었습니다 — 충전이 막힌 채로 남는 게 이 앱의 최악의 실패 모드라서요.",
                    "Whenever the helper exits — manual stop, uninstall, reboot — the SMC is always restored to defaults. This is deliberately not configurable: charging stuck in the inhibited state is the worst failure mode this app has."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(L.s("제어", "Control"))
            }

            SettingsSection {
                HStack {
                    Toggle(isOn: $includeAllKeys) {
                        Text(L.s("SMC 키 전체 열거 (느림)", "Enumerate every SMC key (slow)"))
                    }
                    Spacer()
                    Button(L.s("읽기", "Read")) {
                        model.loadSMCDump(includeAllKeys: includeAllKeys)
                    }
                    .disabled(model.isLoadingDump)
                }

                if model.isLoadingDump {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L.s("SMC 를 읽는 중…", "Reading SMC…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let dump = model.smcDump {
                    SMCDumpTable(dump: dump)

                    HStack {
                        Button(L.s("진단 정보 복사", "Copy diagnostics")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(dump.plainText(), forType: .string)
                            copyFeedback = L.s("클립보드에 복사했습니다.", "Copied to the clipboard.")
                        }
                        if let copyFeedback {
                            Text(copyFeedback)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(L.s(
                        "'읽기'를 누르면 이 맥의 SMC 키 상태를 확인할 수 있습니다. 충전 제어가 안 될 때 여기부터 보세요.",
                        "Press Read to inspect this Mac's SMC keys. Start here when charge control doesn't work."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text(L.s("SMC 진단", "SMC diagnostics"))
            }

            SettingsSection {
                EventLogList()
            } header: {
                Text(L.s("이벤트 로그", "Event log"))
            }

            SettingsSection {
                Button(L.s("SMC 를 기본 상태로 되돌리기", "Reset SMC to defaults")) {
                    showResetConfirm = true
                }
                .confirmationDialog(
                    L.s("SMC 를 기본 상태로 되돌릴까요?", "Reset the SMC to defaults?"),
                    isPresented: $showResetConfirm
                ) {
                    Button(L.s("되돌리기", "Reset"), role: .destructive) {
                        model.run(.resetHardware)
                    }
                    Button(L.s("취소", "Cancel"), role: .cancel) {}
                } message: {
                    Text(L.s(
                        "충전 허용, 어댑터 사용, 펌웨어 제한 해제, MagSafe LED 기본값으로 모두 되돌립니다. 충전 관리가 켜져 있으면 다음 제어 루프에서 다시 적용됩니다.",
                        "Re-enables charging and the adapter, clears the firmware limit and resets the MagSafe LED. If management is on, the next control loop re-applies your settings."
                    ))
                }

                Text(L.s(
                    "완전히 지우려면: sudo ./Scripts/uninstall.sh",
                    "To remove everything: sudo ./Scripts/uninstall.sh"
                ))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            } header: {
                Text(L.s("복구", "Recovery"))
            }
        }
    }

    private var helperStatusText: String {
        switch model.helperState {
        case .unknown: return L.s("확인 중…", "Checking…")
        case .notInstalled: return L.s("설치되지 않음", "Not installed")
        case .unreachable(let detail): return L.s("연결 불가 — ", "Unreachable — ") + detail
        case .ready(let version, let protocolVersion):
            return "paprikad \(version) (protocol \(protocolVersion))"
        }
    }

    private var helperStatusColor: Color {
        switch model.helperState {
        case .ready: return .green
        case .unknown: return .secondary
        default: return .orange
        }
    }
}

// MARK: - SMC 표

private struct SMCDumpTable: View {
    let dump: SMCDump

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(dump.capabilities.system.modelIdentifier)
                Text("·")
                Text(dump.capabilities.backend.label)
                Spacer()
                Text(Fmt.clockTime(dump.generatedAt))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // --all 로 열거하면 같은 키가 두 번 나올 수 있어 인덱스를 id 로 쓴다.
                    ForEach(Array(dump.entries.enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 8) {
                            Text(entry.key)
                                .frame(width: 52, alignment: .leading)
                            Text(entry.dataType)
                                .frame(width: 42, alignment: .leading)
                                .foregroundStyle(.secondary)
                            Text(entry.hex ?? "–")
                                .frame(width: 130, alignment: .leading)
                                .foregroundStyle(entry.error == nil ? .primary : .secondary)
                            if let error = entry.error {
                                Text(error)
                                    .foregroundStyle(.orange)
                                    .lineLimit(1)
                            } else if let value = entry.value {
                                Text(String(format: "%.4g", value))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .font(.system(.caption, design: .monospaced))
                        .padding(.vertical, 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - 이벤트 로그

private struct EventLogList: View {
    @EnvironmentObject private var model: AppModel

    private var events: [PaprikaEvent] {
        model.snapshot?.recentEvents ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if events.isEmpty {
                Text(L.s("아직 기록된 이벤트가 없습니다.", "No events recorded yet."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(events) { event in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: event.kind.symbolName)
                                    .foregroundStyle(event.kind.isProblem ? .orange : .secondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(event.message)
                                        .font(.caption)
                                        .fixedSize(horizontal: false, vertical: true)
                                    HStack(spacing: 6) {
                                        Text(Fmt.clockTime(event.date))
                                        if let percent = event.percent {
                                            Text(Fmt.percent(percent, decimals: 1))
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)

                Button(L.s("로그 비우기", "Clear log")) {
                    model.run(.clearEvents)
                }
                .controlSize(.small)
            }
        }
    }
}
