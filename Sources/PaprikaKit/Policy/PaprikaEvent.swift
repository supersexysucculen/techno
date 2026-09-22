//
//  PaprikaEvent.swift
//  PaprikaKit
//

import Foundation

public struct PaprikaEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case info
        case limitReached
        case chargingResumed
        case temperatureGuard
        case fullChargeDone
        case calibrationPhase
        case calibrationFinished
        case hardwareError
        case configChanged
        case daemonLifecycle

        /// 알림 센터로 띄울 만한 사건인지.
        public var deservesNotification: Bool {
            switch self {
            case .limitReached, .temperatureGuard, .fullChargeDone,
                 .calibrationPhase, .calibrationFinished, .hardwareError:
                return true
            case .info, .chargingResumed, .configChanged, .daemonLifecycle:
                return false
            }
        }

        public var isProblem: Bool { self == .hardwareError }

        public var symbolName: String {
            switch self {
            case .info: return "info.circle"
            case .limitReached: return "pause.circle"
            case .chargingResumed: return "bolt.circle"
            case .temperatureGuard: return "thermometer.high"
            case .fullChargeDone: return "checkmark.circle"
            case .calibrationPhase: return "gauge.with.dots.needle.33percent"
            case .calibrationFinished: return "checkmark.seal"
            case .hardwareError: return "exclamationmark.triangle"
            case .configChanged: return "slider.horizontal.3"
            case .daemonLifecycle: return "gearshape"
            }
        }
    }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var message: String
    public var percent: Double?

    public init(id: UUID = UUID(), date: Date = Date(), kind: Kind, message: String, percent: Double? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.message = message
        self.percent = percent
    }
}
