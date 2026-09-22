//
//  HistoryTab.swift
//  Paprika
//
//  충전량/온도 기록 그래프. Swift Charts (macOS 13+) 를 쓴다.
//

import Charts
import PaprikaKit
import SwiftUI

struct HistoryTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var window: HistoryWindow = .day

    enum HistoryWindow: String, CaseIterable, Identifiable {
        case sixHours
        case day
        case threeDays
        case week

        var id: String { rawValue }

        var hours: Double {
            switch self {
            case .sixHours: return 6
            case .day: return 24
            case .threeDays: return 72
            case .week: return 24 * 7
            }
        }

        var label: String {
            switch self {
            case .sixHours: return L.s("6시간", "6 h")
            case .day: return L.s("1일", "1 day")
            case .threeDays: return L.s("3일", "3 days")
            case .week: return L.s("1주", "1 week")
            }
        }
    }

    private var samples: [HistorySample] {
        let cutoff = Date().addingTimeInterval(-window.hours * 3600)
        return model.history.filter { $0.date >= cutoff }
    }

    var body: some View {
        SettingsForm {
            SettingsSection {
                Picker("", selection: $window) {
                    ForEach(HistoryWindow.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if samples.count < 2 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L.s("아직 기록이 충분하지 않습니다.", "Not enough history yet."))
                        Text(L.s(
                            "\(Int(model.settings.historySampleSeconds))초마다 한 점씩 쌓입니다. 잠시 켜 두면 그래프가 그려집니다.",
                            "One sample every \(Int(model.settings.historySampleSeconds))s. Leave it running for a while."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
                } else {
                    chargeChart
                }
            } header: {
                Text(L.s("충전량", "Charge level"))
            }

            if samples.contains(where: { $0.temperature != nil }) {
                SettingsSection {
                    temperatureChart
                } header: {
                    Text(L.s("배터리 온도", "Battery temperature"))
                }
            }

            SettingsSection {
                HStack {
                    Text(L.s("보관 기간", "Retention"))
                    Spacer()
                    Text(L.s("\(model.settings.historyRetentionDays)일", "\(model.settings.historyRetentionDays) days"))
                        .foregroundStyle(.secondary)
                    Stepper(
                        value: Binding(
                            get: { Double(model.settings.historyRetentionDays) },
                            set: { model.settings.historyRetentionDays = Int($0) }
                        ),
                        in: 1...90,
                        step: 1
                    ) {
                        EmptyView()
                    }
                    .labelsHidden()
                }

                LabeledStepper(
                    title: L.s("샘플 간격", "Sample interval"),
                    value: Binding(
                        get: { model.settings.historySampleSeconds },
                        set: { model.settings.historySampleSeconds = $0 }
                    ),
                    range: 15...600,
                    step: 15,
                    format: { String(format: "%.0f\(L.s("초", " s"))", $0) }
                )

                HStack {
                    Text(L.s("파일 크기", "File size"))
                    Spacer()
                    Text(model.historyFileSizeDescription)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                HStack {
                    Button(L.s("다시 읽기", "Reload")) { model.reloadHistory() }
                    Button(L.s("기록 전체 삭제", "Delete all history"), role: .destructive) {
                        model.deleteHistory()
                    }
                }
            } header: {
                Text(L.s("기록 관리", "History settings"))
            }
        }
        .onAppear { model.reloadHistory() }
    }

    // MARK: 차트

    private var chargeChart: some View {
        Chart {
            ForEach(samples) { sample in
                AreaMark(
                    x: .value(L.s("시각", "Time"), sample.date),
                    y: .value(L.s("충전량", "Charge"), sample.percent)
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.03)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value(L.s("시각", "Time"), sample.date),
                    y: .value(L.s("충전량", "Charge"), sample.percent)
                )
                .foregroundStyle(Color.accentColor)
                .interpolationMethod(.monotone)
            }

            // 상한선 (Y축이 Double 이므로 Int 를 그대로 넣으면 안 된다)
            if let limit = samples.last?.limit {
                RuleMark(y: .value(L.s("상한", "Limit"), Double(limit)))
                    .foregroundStyle(.orange.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("\(limit)%")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
            }
        }
        .chartYScale(domain: 0.0...100.0)
        .chartYAxis {
            AxisMarks(values: [0.0, 25.0, 50.0, 75.0, 100.0]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let percent = value.as(Double.self) {
                        Text("\(Int(percent))%")
                    }
                }
            }
        }
        .frame(height: 190)
    }

    private var temperatureChart: some View {
        Chart {
            ForEach(samples.filter { $0.temperature != nil }) { sample in
                LineMark(
                    x: .value(L.s("시각", "Time"), sample.date),
                    y: .value(L.s("온도", "Temperature"), sample.temperature ?? 0)
                )
                .foregroundStyle(Color.red.opacity(0.8))
                .interpolationMethod(.monotone)
            }
            if model.draftConfig.temperatureGuardEnabled {
                RuleMark(y: .value(L.s("한계", "Limit"), model.draftConfig.temperatureLimit))
                    .foregroundStyle(.red.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let celsius = value.as(Double.self) {
                        Text(String(format: "%.0f°", celsius))
                    }
                }
            }
        }
        .frame(height: 150)
    }
}
