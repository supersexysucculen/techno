//
//  HelperService.swift
//  paprikad
//
//  XPC 진입점. 하는 일은 얇다: 검증 → ChargeController 로 넘김 → JSON 으로 응답.
//

import Foundation
import PaprikaKit

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let controller: ChargeController

    init(controller: ChargeController) {
        self.controller = controller
        super.init()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let verdict = PeerValidator.evaluate(connection: newConnection)
        guard verdict.allowed else {
            PaprikaLog.ipc.error("연결을 거부했습니다 — \(verdict.detail, privacy: .public)")
            return false
        }
        PaprikaLog.ipc.info("연결을 수락했습니다 — \(verdict.detail, privacy: .public)")

        newConnection.exportedInterface = PaprikaIPC.makeInterface()
        newConnection.exportedObject = HelperService(controller: controller)
        newConnection.resume()
        return true
    }
}

final class HelperService: NSObject, PaprikaHelperProtocol {
    private let controller: ChargeController

    init(controller: ChargeController) {
        self.controller = controller
        super.init()
    }

    // MARK: - PaprikaHelperProtocol

    func handshake(reply: @escaping (String, Int) -> Void) {
        reply(PaprikaVersion.current, PaprikaIPC.protocolVersion)
    }

    func fetchSnapshot(reply: @escaping (Data?, String?) -> Void) {
        controller.snapshot { result in
            Self.respond(result, reply: reply)
        }
    }

    func updateConfig(_ configJSON: Data, reply: @escaping (Data?, String?) -> Void) {
        let config: PaprikaConfig
        do {
            config = try PaprikaCoding.decode(PaprikaConfig.self, from: configJSON)
        } catch {
            reply(nil, L.s("설정 데이터를 읽지 못했습니다: ", "Could not decode config: ") + String(describing: error))
            return
        }
        controller.updateConfig(config) { result in
            Self.respond(result, reply: reply)
        }
    }

    func performCommand(_ name: String, payload: Data?, reply: @escaping (Data?, String?) -> Void) {
        guard let command = PaprikaCommand(rawValue: name) else {
            reply(nil, L.s("알 수 없는 명령: ", "Unknown command: ") + name)
            return
        }
        controller.perform(command: command, payload: payload) { result in
            Self.respond(result, reply: reply)
        }
    }

    func smcDump(includeAllKeys: Bool, reply: @escaping (Data?, String?) -> Void) {
        controller.dump(includeAllKeys: includeAllKeys) { result in
            Self.respond(result, reply: reply)
        }
    }

    func restoreAndExit(reply: @escaping (String?) -> Void) {
        PaprikaLog.ipc.notice("restoreAndExit 요청을 받았습니다.")
        controller.shutdown(restoreHardware: true)
        reply(nil)
        // launchd 가 KeepAlive 로 되살리지 않도록, 언인스톨 스크립트가 먼저
        // bootout 을 하는 것이 정석이다. 그래도 여기서는 확실히 빠져나간다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            exit(0)
        }
    }

    // MARK: - 응답 헬퍼

    private static func respond<T: Encodable>(
        _ result: Result<T, Error>,
        reply: @escaping (Data?, String?) -> Void
    ) {
        switch result {
        case .success(let value):
            do {
                reply(try PaprikaCoding.encode(value), nil)
            } catch {
                reply(nil, L.s("응답을 만들지 못했습니다: ", "Could not encode reply: ") + String(describing: error))
            }
        case .failure(let error):
            reply(nil, String(describing: error))
        }
    }
}
