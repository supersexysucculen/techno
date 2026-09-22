//
//  PepperIconRenderer.swift
//  Paprika
//
//  메뉴바에 올릴 NSImage 를 그린다.
//
//  메뉴바 높이에 맞춰 18pt 로 그리고, 화면 배율은 NSImage 가 알아서 처리한다.
//  `flipped: true` 로 그려서 PepperGeometry 의 y-down 좌표계를 그대로 쓴다.
//

import AppKit
import SwiftUI

enum PepperIconRenderer {

    /// 메뉴바 아이콘 한 장.
    /// - Parameters:
    ///   - fraction: 0...1 충전량
    ///   - state: 색과 오버레이 기호를 결정
    ///   - style: 사용자가 고른 스타일
    ///   - height: 메뉴바 아이콘 높이(pt)
    static func image(
        fraction: Double,
        state: PepperVisualState,
        style: MenuBarIconStyle,
        height: CGFloat = 18
    ) -> NSImage {
        switch style {
        case .emoji:
            return emojiImage(height: height)
        case .textOnly:
            // 라벨 쪽에서 텍스트만 보여주므로 빈(투명) 이미지를 준다.
            let empty = NSImage(size: NSSize(width: 1, height: height))
            empty.isTemplate = true
            return empty
        case .pepper:
            return pepperImage(fraction: fraction, state: state, monochrome: false, height: height)
        case .pepperMonochrome:
            return pepperImage(fraction: fraction, state: state, monochrome: true, height: height)
        }
    }

    // MARK: 파프리카

    private static func pepperImage(
        fraction: Double,
        state: PepperVisualState,
        monochrome: Bool,
        height: CGFloat
    ) -> NSImage {
        // 파프리카는 세로로 살짝 길다.
        let size = NSSize(width: (height * 0.86).rounded(), height: height)

        let image = NSImage(size: size, flipped: true) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            // 꼭지/외곽선을 위해 살짝 안쪽으로 줄인다.
            let inset = PepperGeometry.outlineWidth(for: bounds) / 2
            let rect = bounds.insetBy(dx: inset, dy: inset)

            let bodyPath = PepperGeometry.body(in: rect)
            let stemPath = PepperGeometry.stem(in: rect)

            let tint: NSColor = monochrome ? .black : state.nsAccentColor

            // 1) 몸통 배경 (옅게)
            context.saveGState()
            context.addPath(bodyPath)
            context.setFillColor(tint.withAlphaComponent(monochrome ? 0.18 : 0.20).cgColor)
            context.fillPath()
            context.restoreGState()

            // 2) 충전량만큼 채우기 (몸통으로 clip)
            context.saveGState()
            context.addPath(bodyPath)
            context.clip()
            let fill = PepperGeometry.fillRect(fraction: fraction, in: rect)
            context.setFillColor(tint.withAlphaComponent(monochrome ? 1.0 : 0.95).cgColor)
            context.fill(fill)
            context.restoreGState()

            // 3) 외곽선
            context.saveGState()
            context.addPath(bodyPath)
            context.setStrokeColor(tint.cgColor)
            context.setLineWidth(PepperGeometry.outlineWidth(for: rect))
            context.strokePath()
            context.restoreGState()

            // 4) 꼭지
            context.saveGState()
            context.addPath(stemPath)
            context.setStrokeColor(tint.cgColor)
            context.setLineWidth(PepperGeometry.stemLineWidth(for: rect))
            context.setLineCap(.round)
            context.strokePath()
            context.restoreGState()

            return true
        }

        // 단색 스타일은 템플릿으로 넘겨서 메뉴바 테마를 따라가게 한다.
        image.isTemplate = monochrome
        image.accessibilityDescription = state.label
        return image
    }

    // MARK: 이모지

    private static func emojiImage(height: CGFloat) -> NSImage {
        let text = "🫑" as NSString
        let font = NSFont.systemFont(ofSize: height * 0.86)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        var textSize = text.size(withAttributes: attributes)
        // 이모지 폰트가 없는 환경(아주 옛 시스템)에서는 크기가 0 이 될 수 있다.
        if textSize.width < 1 || textSize.height < 1 {
            textSize = NSSize(width: height, height: height)
        }

        let canvasSize = NSSize(width: ceil(textSize.width), height: height)
        let image = NSImage(size: canvasSize, flipped: false) { _ in
            let origin = NSPoint(x: 0, y: (height - textSize.height) / 2)
            text.draw(at: origin, withAttributes: attributes)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Paprika"
        return image
    }

    // MARK: 앱 아이콘 (Scripts/make-icon.swift 에서도 씀)

    /// 정사각형 앱 아이콘. 배경 라운드 사각형 + 파프리카.
    static func appIcon(size pixelSize: CGFloat) -> NSImage {
        let size = NSSize(width: pixelSize, height: pixelSize)
        let image = NSImage(size: size, flipped: true) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            // 배경
            let backgroundRect = bounds.insetBy(dx: bounds.width * 0.06, dy: bounds.width * 0.06)
            let radius = backgroundRect.width * 0.22
            let background = CGPath(
                roundedRect: backgroundRect,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
            context.saveGState()
            context.addPath(background)
            context.setFillColor(NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.16, alpha: 1).cgColor)
            context.fillPath()
            context.restoreGState()

            // 파프리카
            let pepperRect = bounds.insetBy(dx: bounds.width * 0.22, dy: bounds.width * 0.18)
            let bodyPath = PepperGeometry.body(in: pepperRect)
            let stemPath = PepperGeometry.stem(in: pepperRect)
            let leafPath = PepperGeometry.leaf(in: pepperRect)

            context.saveGState()
            context.addPath(bodyPath)
            context.setFillColor(NSColor(calibratedRed: 0.95, green: 0.29, blue: 0.24, alpha: 1).cgColor)
            context.fillPath()
            context.restoreGState()

            // 하이라이트
            context.saveGState()
            context.addPath(bodyPath)
            context.clip()
            let highlight = CGRect(
                x: pepperRect.minX + pepperRect.width * 0.16,
                y: pepperRect.minY + pepperRect.height * 0.32,
                width: pepperRect.width * 0.16,
                height: pepperRect.height * 0.34
            )
            context.setFillColor(NSColor.white.withAlphaComponent(0.28).cgColor)
            context.fillEllipse(in: highlight)
            context.restoreGState()

            let green = NSColor(calibratedRed: 0.29, green: 0.66, blue: 0.33, alpha: 1)

            context.saveGState()
            context.addPath(leafPath)
            context.setFillColor(green.cgColor)
            context.fillPath()
            context.restoreGState()

            context.saveGState()
            context.addPath(stemPath)
            context.setStrokeColor(green.cgColor)
            context.setLineWidth(PepperGeometry.stemLineWidth(for: pepperRect))
            context.setLineCap(.round)
            context.strokePath()
            context.restoreGState()

            return true
        }
        return image
    }
}
