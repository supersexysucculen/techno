//
//  PowerWatcher.swift
//  paprikad
//
//  두 가지 시스템 알림을 받는다:
//
//   1) 절전에서 깨어남 (kIOMessageSystemHasPoweredOn)
//      — 잠들었다 깨면 SMC 값이 기본값으로 돌아가는 경우가 있다. 깨어나자마자
//        우리가 원하는 상태를 다시 써줘야 한다.
//   2) 전원 소스 변화 (어댑터 연결/분리)
//      — 5초 폴링을 기다리지 않고 즉시 반응하려고.
//

import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import PaprikaKit

/// IOKit 의 메시지 상수는 툴체인에 따라 Int / Int32 / UInt32 로 들어온다.
/// 비교 전에 UInt32 비트패턴으로 통일한다.
private func ioMessageCode<T: BinaryInteger>(_ value: T) -> UInt32 {
    UInt32(bitPattern: Int32(truncatingIfNeeded: value))
}

final class PowerWatcher {
    /// 절전에서 깨어났을 때
    var onWake: (() -> Void)?
    /// 전원 소스가 바뀌었을 때
    var onPowerSourceChange: (() -> Void)?

    private var rootPowerPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifierObject: io_object_t = 0
    private var powerSourceRunLoopSource: CFRunLoopSource?

    func start() {
        startSleepWakeWatch()
        startPowerSourceWatch()
    }

    func stop() {
        if let notificationPort {
            if let source = IONotificationPortGetRunLoopSource(notificationPort)?.takeUnretainedValue() {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            }
            if notifierObject != 0 {
                _ = IODeregisterForSystemPower(&notifierObject)
                notifierObject = 0
            }
            if rootPowerPort != 0 {
                _ = IOServiceClose(rootPowerPort)
                rootPowerPort = 0
            }
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
        if let powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .defaultMode)
            self.powerSourceRunLoopSource = nil
        }
    }

    // MARK: 절전/깨어남

    private func startSleepWakeWatch() {
        var port: IONotificationPortRef?
        var notifier: io_object_t = 0
        let context = Unmanaged.passUnretained(self).toOpaque()

        let connection = IORegisterForSystemPower(
            context,
            &port,
            { (refcon, _, messageType, argument) in
                guard let refcon else { return }
                let watcher = Unmanaged<PowerWatcher>.fromOpaque(refcon).takeUnretainedValue()
                watcher.handleSystemPowerMessage(messageType, argument: argument)
            },
            &notifier
        )

        guard connection != 0, let port else {
            PaprikaLog.daemon.error("IORegisterForSystemPower 실패 — 깨어남 감지를 못 합니다.")
            return
        }

        rootPowerPort = connection
        notificationPort = port
        notifierObject = notifier

        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        PaprikaLog.daemon.info("절전/깨어남 감지를 시작했습니다.")
    }

    fileprivate func handleSystemPowerMessage(_ messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case ioMessageCode(kIOMessageCanSystemSleep):
            // 절전을 막을 이유가 없다. 바로 허용해야 30초 타임아웃을 안 먹는다.
            _ = IOAllowPowerChange(rootPowerPort, Int(bitPattern: argument))
        case ioMessageCode(kIOMessageSystemWillSleep):
            _ = IOAllowPowerChange(rootPowerPort, Int(bitPattern: argument))
        case ioMessageCode(kIOMessageSystemHasPoweredOn):
            PaprikaLog.daemon.info("절전에서 깨어났습니다 — SMC 상태를 다시 적용합니다.")
            onWake?()
        default:
            break
        }
    }

    // MARK: 전원 소스

    private func startPowerSourceWatch() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource(
            { refcon in
                guard let refcon else { return }
                let watcher = Unmanaged<PowerWatcher>.fromOpaque(refcon).takeUnretainedValue()
                watcher.onPowerSourceChange?()
            },
            context
        )?.takeRetainedValue() else {
            PaprikaLog.daemon.error("IOPSNotificationCreateRunLoopSource 실패 — 어댑터 변화 감지를 못 합니다.")
            return
        }
        powerSourceRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        PaprikaLog.daemon.info("전원 소스 변화 감지를 시작했습니다.")
    }
}
