//
//  PepperGeometry.swift
//  Paprika
//
//  파프리카(피망) 실루엣을 CGPath 로 만든다.
//
//  좌표계는 y 가 아래로 증가하는 방향(SwiftUI 기준)으로 100×100 박스 안에서
//  정의했다. AppKit 에서 쓸 때는 NSImage(size:flipped:true,...) 로 그려서
//  같은 좌표계를 유지한다.
//
//  SF Symbols 에는 피망이 없어서 직접 그렸다. 모양이 마음에 안 들면 아래 제어점
//  숫자만 만지면 된다 — 메뉴바 아이콘과 팝오버 게이지가 같은 경로를 공유한다.
//

import CoreGraphics
import Foundation

enum PepperGeometry {

    private static func point(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + x / 100 * rect.width,
            y: rect.minY + y / 100 * rect.height
        )
    }

    /// 파프리카 몸통. 아래쪽에 두 개의 볼록한 로브와 가운데 오목한 홈이 있다.
    static func body(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { point(x, y, in: rect) }

        path.move(to: p(50, 27))
        // 오른쪽 어깨
        path.addCurve(to: p(88, 53), control1: p(74, 23), control2: p(87, 32))
        // 오른쪽 옆구리 → 오른쪽 로브
        path.addCurve(to: p(73, 92), control1: p(90, 73), control2: p(88, 87))
        // 오른쪽 로브 → 가운데 홈
        path.addCurve(to: p(50, 83), control1: p(63, 96), control2: p(56, 90))
        // 가운데 홈 → 왼쪽 로브
        path.addCurve(to: p(27, 92), control1: p(44, 90), control2: p(37, 96))
        // 왼쪽 로브 → 왼쪽 옆구리
        path.addCurve(to: p(12, 53), control1: p(12, 87), control2: p(10, 73))
        // 왼쪽 어깨 → 시작점
        path.addCurve(to: p(50, 27), control1: p(13, 32), control2: p(26, 23))
        path.closeSubpath()
        return path
    }

    /// 꼭지. 두껍게 stroke 해서 쓴다.
    static func stem(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { point(x, y, in: rect) }

        path.move(to: p(50, 30))
        path.addCurve(to: p(60, 9), control1: p(51, 22), control2: p(55, 13))
        return path
    }

    /// 꼭지 옆의 작은 잎. 큰 크기에서만 그린다(작으면 뭉개진다).
    static func leaf(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { point(x, y, in: rect) }

        path.move(to: p(50, 28))
        path.addCurve(to: p(28, 17), control1: p(42, 27), control2: p(32, 24))
        path.addCurve(to: p(50, 28), control1: p(35, 25), control2: p(43, 30))
        path.closeSubpath()
        return path
    }

    /// stroke 에 쓰기 좋은 꼭지 굵기.
    static func stemLineWidth(for rect: CGRect) -> CGFloat {
        max(1, rect.width * 0.085)
    }

    /// 몸통 외곽선 굵기.
    static func outlineWidth(for rect: CGRect) -> CGFloat {
        max(0.8, rect.width * 0.055)
    }

    /// 충전량을 몸통 안에서 채울 사각형으로 바꾼다. (y 아래로 증가하므로 위에서 깎는다)
    ///
    /// 몸통은 y 27~92 구간만 차지하므로, 0% 일 때 완전히 비고 100% 일 때 꽉 차도록
    /// 그 구간에 맞춰 매핑한다.
    static func fillRect(fraction: Double, in rect: CGRect) -> CGRect {
        let clamped = max(0, min(1, fraction))
        let bodyTop = rect.minY + 0.26 * rect.height
        let bodyBottom = rect.minY + 0.93 * rect.height
        let bodyHeight = bodyBottom - bodyTop
        let filledHeight = bodyHeight * clamped
        return CGRect(
            x: rect.minX,
            y: bodyBottom - filledHeight,
            width: rect.width,
            height: filledHeight
        )
    }
}
