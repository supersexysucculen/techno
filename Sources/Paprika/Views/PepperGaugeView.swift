//
//  PepperGaugeView.swift
//  Paprika
//
//  팝오버 안에 크게 보여주는 파프리카 게이지. 메뉴바 아이콘과 같은 경로를 쓴다.
//

import PaprikaKit
import SwiftUI

/// SwiftUI 에서 PepperGeometry 를 쓰기 위한 Shape 들.
struct PepperBodyShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(PepperGeometry.body(in: rect))
    }
}

struct PepperStemShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(PepperGeometry.stem(in: rect))
    }
}

struct PepperLeafShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(PepperGeometry.leaf(in: rect))
    }
}

struct PepperGaugeView: View {
    let fraction: Double
    let state: PepperVisualState
    /// 상한선을 게이지 위에 그릴 위치(0...1). nil 이면 안 그린다.
    let limitFraction: Double?
    var size: CGFloat = 92
    var showOverlaySymbol: Bool = true

    private var clampedFraction: Double { max(0, min(1, fraction)) }

    var body: some View {
        GeometryReader { geometry in
            let rect = CGRect(origin: .zero, size: geometry.size)
            let fill = PepperGeometry.fillRect(fraction: clampedFraction, in: rect)
            let outline = PepperGeometry.outlineWidth(for: rect)

            ZStack {
                // 옅은 몸통
                PepperBodyShape()
                    .fill(state.accentColor.opacity(0.16))

                // 충전량
                PepperBodyShape()
                    .fill(state.accentColor)
                    .mask { Path(fill).fill(Color.white) }

                // 상한선
                if let limitFraction, limitFraction > 0.02, limitFraction < 0.99 {
                    let limitRect = PepperGeometry.fillRect(fraction: limitFraction, in: rect)
                    Path { path in
                        path.move(to: CGPoint(x: rect.minX, y: limitRect.minY))
                        path.addLine(to: CGPoint(x: rect.maxX, y: limitRect.minY))
                    }
                    .stroke(
                        Color.primary.opacity(0.55),
                        style: StrokeStyle(lineWidth: max(1, outline * 0.5), dash: [3, 2])
                    )
                    .mask { PepperBodyShape().fill(Color.white) }
                }

                // 외곽선 + 꼭지
                PepperBodyShape()
                    .stroke(state.accentColor, lineWidth: outline)
                PepperStemShape()
                    .stroke(
                        Color(red: 0.29, green: 0.6, blue: 0.33),
                        style: StrokeStyle(
                            lineWidth: PepperGeometry.stemLineWidth(for: rect),
                            lineCap: .round
                        )
                    )
                PepperLeafShape()
                    .fill(Color(red: 0.29, green: 0.6, blue: 0.33))

                if showOverlaySymbol, let symbol = state.overlaySymbol {
                    Image(systemName: symbol)
                        .font(.system(size: geometry.size.width * 0.3, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                        .offset(y: geometry.size.height * 0.08)
                }
            }
        }
        .frame(width: size * 0.86, height: size)
        .accessibilityLabel(Text(state.label))
        .accessibilityValue(Text(Fmt.percent(clampedFraction * 100)))
    }
}

/// 배터리 퍼센트 + 상태를 가로로 보여주는 헤더.
struct BatteryHeaderView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            PepperGaugeView(
                fraction: model.displayPercent / 100,
                state: model.visualState,
                limitFraction: model.snapshot.map { Double($0.decision.effectiveTarget) / 100 },
                size: 84
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.0f", model.displayPercent))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("%")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)
                }

                Text(model.statusHeadline)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = model.statusDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let remaining = timeRemainingText {
                    Text(remaining)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var timeRemainingText: String? {
        guard let battery = model.battery else { return nil }
        if battery.isCharging, let minutes = battery.minutesToFull {
            return L.s("완충까지 약 ", "About ") + Fmt.duration(minutes: minutes) + L.s("", " to full")
        }
        if !battery.isPluggedIn, let minutes = battery.minutesToEmpty {
            return L.s("사용 가능 약 ", "About ") + Fmt.duration(minutes: minutes) + L.s(" 남음", " left")
        }
        return nil
    }
}
