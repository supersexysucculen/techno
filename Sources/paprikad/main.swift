//
//  main.swift
//  paprikad — Paprika 권한 도우미 (LaunchDaemon, root)
//
//  launchd 가 /Library/LaunchDaemons/com.paprika.helperd.plist 로 실행한다.
//  메뉴바 앱은 XPC(mach service com.paprika.helperd)로 여기에 붙는다.
//
//  직접 실행해서 확인하고 싶으면:
//      sudo /Library/PrivilegedHelperTools/com.paprika.helperd --check
//      sudo /Library/PrivilegedHelperTools/com.paprika.helperd --restore
//

import Foundation
import PaprikaKit

setvbuf(stdout, nil, _IOLBF, 0)
setvbuf(stderr, nil, _IONBF, 0)

private func printErr(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--version") {
    print("paprikad \(PaprikaVersion.current) (protocol \(PaprikaIPC.protocolVersion))")
    exit(0)
}

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    paprikad \(PaprikaVersion.current) — Paprika 권한 도우미

      (인수 없음)   launchd 데몬으로 동작한다.
      --check       SMC 접근과 충전 제어 지원 여부만 확인하고 종료한다 (읽기만).
      --restore     충전 허용·어댑터 사용·펌웨어 제한 해제로 SMC 를 되돌리고 종료한다.
                    데몬이 실행 중이 아니어도 동작하므로, 언인스톨의 마지막 안전망이다.
      --version     버전을 출력한다.
    """)
    exit(0)
}

guard geteuid() == 0 else {
    printErr("paprikad 는 root 로 실행해야 합니다 (SMC 쓰기 권한 필요).")
    printErr("launchd 로 설치하려면: sudo ./Scripts/install-helper.sh")
    exit(77)  // EX_NOPERM
}

// MARK: - --restore: 데몬 없이도 하드웨어를 되돌리는 최후의 수단
//
// 언인스톨 스크립트가 바이너리를 지우기 **전에** 이걸 부른다.
// 데몬이 이미 죽어 있거나 paprikactl 이 없어도 동작해야 하므로, 여기서는 XPC 도
// 상태 파일도 쓰지 않고 SMC 만 직접 되돌린다.

if arguments.contains("--restore") {
    do {
        let connection = try SMCConnection()
        let hardware = ChargeHardware(smc: connection)
        guard hardware.capabilities.isUsable else {
            print("되돌릴 충전 제어 키가 없습니다 — 할 일이 없습니다.")
            exit(0)
        }
        let failures = hardware.restoreDefaults()
        if failures.isEmpty {
            print("SMC 를 기본 상태로 되돌렸습니다 (충전 허용, 어댑터 사용, 펌웨어 제한 해제).")
            exit(0)
        }
        printErr("일부 항목을 되돌리지 못했습니다:")
        for failure in failures {
            printErr("  - \(failure)")
        }
        printErr("맥을 완전히 껐다 켜면 SMC 값이 초기화됩니다.")
        exit(1)
    } catch {
        printErr("SMC 에 접근할 수 없습니다: \(error)")
        exit(1)
    }
}

// MARK: - --check: 설치 직후 문제를 빨리 확인하는 용도

if arguments.contains("--check") {
    do {
        let connection = try SMCConnection()
        let hardware = ChargeHardware(smc: connection)
        let capabilities = hardware.capabilities
        print("model         : \(capabilities.system.modelIdentifier)")
        print("chip          : \(capabilities.system.chipName)")
        print("appleSilicon  : \(capabilities.system.isAppleSilicon)")
        print("os            : \(capabilities.system.osVersion)")
        print("backend       : \(capabilities.backend.rawValue)")
        print("adapterKey    : \(capabilities.adapterKey.rawValue.isEmpty ? "(없음)" : capabilities.adapterKey.rawValue)")
        print("firmwareKeys  : \(capabilities.hasFirmwareLimitKeys)")
        print("directKeys    : \(capabilities.hasDirectKeys)")
        print("magSafeLED    : \(capabilities.hasMagSafeLED)")
        print("usableKeys    : \(capabilities.usableKeys.keys.sorted().joined(separator: ", "))")
        if let battery = BatteryReader().read() {
            print(String(format: "battery       : %.1f%% charging=%@ plugged=%@",
                         battery.precisePercent,
                         battery.isCharging ? "yes" : "no",
                         battery.isPluggedIn ? "yes" : "no"))
        }
        exit(capabilities.isUsable ? 0 : 1)
    } catch {
        printErr("SMC 에 접근할 수 없습니다: \(error)")
        exit(1)
    }
}

// MARK: - 데몬 본체

PaprikaLog.daemon.notice("paprikad \(PaprikaVersion.current, privacy: .public) 시작 (pid \(getpid(), privacy: .public))")

let controller = ChargeController()
let listenerDelegate = HelperListenerDelegate(controller: controller)
let listener = NSXPCListener(machServiceName: PaprikaIPC.machServiceName)
listener.delegate = listenerDelegate
listener.resume()

controller.start()

/// SIGTERM / SIGINT 을 받으면 하드웨어를 되돌리고 나간다.
/// 이게 없으면 데몬을 멈춘 뒤에도 충전이 막힌 채로 남을 수 있다.
let shutdownSignals: [Int32] = [SIGTERM, SIGINT, SIGHUP]
let signalSources: [DispatchSourceSignal] = shutdownSignals.map { signalNumber in
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        PaprikaLog.daemon.notice("시그널 \(signalNumber, privacy: .public) 수신 — 정리 후 종료합니다.")
        controller.shutdown(restoreHardware: true)
        exit(0)
    }
    source.resume()
    return source
}
// 소스를 살려 두기 위한 참조.
_ = signalSources

RunLoop.main.run()
