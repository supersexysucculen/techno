//
//  HelperConnection.swift
//  PaprikaKit
//
//  paprikad XPC 클라이언트. 메뉴바 앱과 paprikactl 이 함께 쓴다.
//
//  설계 메모
//  --------
//  * 데몬이 설치돼 있지 않으면 mach service 가 없어서 연결이 즉시 실패한다.
//    그 경우 UI 에 "설치 안내"를 보여줘야 하므로, 실패 이유를 구분해서 돌려준다.
//  * XPC 응답이 영원히 안 오는 상황(데몬이 멈춤 등)에 UI 가 잠기지 않도록
//    모든 호출에 타임아웃을 붙였다.
//

import Foundation

public enum HelperClientError: LocalizedError {
    case notInstalled
    case connectionFailed(String)
    case remote(String)
    case timeout
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return L.s(
                "권한 도우미(paprikad)가 설치되어 있지 않습니다.",
                "The privileged helper (paprikad) is not installed."
            )
        case .connectionFailed(let detail):
            return L.s("도우미에 연결할 수 없습니다: ", "Could not connect to the helper: ") + detail
        case .remote(let message):
            return message
        case .timeout:
            return L.s("도우미가 응답하지 않습니다.", "The helper did not respond.")
        case .decoding(let detail):
            return L.s("도우미 응답을 해석할 수 없습니다: ", "Could not decode the helper reply: ") + detail
        }
    }
}

/// 데몬 설치/연결 상태.
public enum HelperState: Equatable {
    case unknown
    case notInstalled
    case unreachable(String)
    case ready(version: String, protocolVersion: Int)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// 앱과 데몬의 프로토콜 버전이 어긋났는지.
    public var hasVersionMismatch: Bool {
        if case .ready(_, let protocolVersion) = self {
            return protocolVersion != PaprikaIPC.protocolVersion
        }
        return false
    }
}

public final class HelperConnection {

    private var connection: NSXPCConnection?
    private let timeout: TimeInterval
    private let completionQueue: DispatchQueue
    private let lock = NSLock()

    /// 연결 끊김 알림의 최소 간격. 재연결 폭주를 막는다.
    private static let dropNotifyInterval: TimeInterval = 5
    private var lastDropNotifiedAt: Date?

    /// 연결이 끊겼을 때 호출된다(메인 큐).
    public var onConnectionLost: (() -> Void)?

    /// - Parameters:
    ///   - timeout: 응답을 기다리는 최대 시간.
    ///   - completionQueue: completion 을 호출할 큐. GUI 는 .main, CLI 는 백그라운드 큐를
    ///     써야 한다(메인 스레드를 세마포어로 막으면 .main 이 영원히 안 돌아간다).
    public init(timeout: TimeInterval = 5, completionQueue: DispatchQueue = .main) {
        self.timeout = timeout
        self.completionQueue = completionQueue
    }

    // MARK: 설치 여부

    /// launchd plist 와 실행 파일이 제자리에 있는지 확인한다.
    /// (연결 실패 원인을 "미설치"와 "고장"으로 구분하기 위한 값싼 검사)
    public static var isHelperInstalled: Bool {
        FileManager.default.fileExists(atPath: PaprikaPaths.helperLaunchDaemonPlist)
            && FileManager.default.fileExists(atPath: PaprikaPaths.helperExecutable)
    }

    // MARK: 연결 관리

    private func activeConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }

        if let connection { return connection }

        let newConnection = NSXPCConnection(
            machServiceName: PaprikaIPC.machServiceName,
            options: .privileged
        )
        newConnection.remoteObjectInterface = PaprikaIPC.makeInterface()

        // 연결이 끊기면 알려주긴 하되, **즉시 재연결을 유도하지는 않는다.**
        //
        // 데몬이 "설치돼 있지만 실행 중이 아닌" 상태(업그레이드 중, 언인스톨 중)에서는
        // 연결 시도 → 즉시 invalidate → 알림 → 재연결이 지연 없이 반복되며 메인 큐를
        // 태우고 launchd 로그를 도배한다. 그래서 최소 간격을 두고, 그 사이의 끊김은
        // 조용히 넘긴다. 어차피 앱의 폴링 타이머가 곧 다시 시도한다.
        let handleDrop: () -> Void = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.connection = nil
            let now = Date()
            let shouldNotify: Bool
            if let last = self.lastDropNotifiedAt, now.timeIntervalSince(last) < Self.dropNotifyInterval {
                shouldNotify = false
            } else {
                self.lastDropNotifiedAt = now
                shouldNotify = true
            }
            self.lock.unlock()

            guard shouldNotify else { return }
            self.completionQueue.async { self.onConnectionLost?() }
        }
        newConnection.invalidationHandler = handleDrop
        newConnection.interruptionHandler = handleDrop

        newConnection.resume()
        connection = newConnection
        return newConnection
    }

    public func invalidate() {
        lock.lock()
        let existing = connection
        connection = nil
        lock.unlock()
        existing?.invalidate()
    }

    // MARK: 호출 래퍼

    /// 한 번만 호출되도록 보장하는 completion + 타임아웃.
    private func guarded<T>(
        _ completion: @escaping (Result<T, Error>) -> Void
    ) -> (Result<T, Error>) -> Void {
        let hasFired = AtomicFlag()
        let queue = completionQueue
        let wrapped: (Result<T, Error>) -> Void = { result in
            guard hasFired.trySet() else { return }
            queue.async { completion(result) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard hasFired.trySet() else { return }
            queue.async { completion(.failure(HelperClientError.timeout)) }
        }
        return wrapped
    }

    private func proxy<T>(
        _ finish: @escaping (Result<T, Error>) -> Void
    ) -> PaprikaHelperProtocol? {
        guard Self.isHelperInstalled else {
            finish(.failure(HelperClientError.notInstalled))
            return nil
        }
        let connection = activeConnection()
        guard let remote = connection.remoteObjectProxyWithErrorHandler({ error in
            finish(.failure(HelperClientError.connectionFailed(error.localizedDescription)))
        }) as? PaprikaHelperProtocol else {
            finish(.failure(HelperClientError.connectionFailed(
                L.s("프록시를 만들 수 없습니다.", "Could not create the remote proxy.")
            )))
            return nil
        }
        return remote
    }

    /// (Data?, String?) 형태의 응답을 Result<T, Error> 로 바꾼다.
    private func decodeReply<T: Decodable>(
        _ type: T.Type,
        data: Data?,
        errorMessage: String?,
        finish: @escaping (Result<T, Error>) -> Void
    ) {
        if let errorMessage {
            finish(.failure(HelperClientError.remote(errorMessage)))
            return
        }
        guard let data else {
            finish(.failure(HelperClientError.remote(
                L.s("도우미가 빈 응답을 보냈습니다.", "The helper sent an empty reply.")
            )))
            return
        }
        do {
            finish(.success(try PaprikaCoding.decode(type, from: data)))
        } catch {
            finish(.failure(HelperClientError.decoding(String(describing: error))))
        }
    }

    // MARK: API

    public func handshake(completion: @escaping (Result<HelperState, Error>) -> Void) {
        let finish = guarded(completion)
        guard Self.isHelperInstalled else {
            finish(.success(.notInstalled))
            return
        }
        let connection = activeConnection()
        guard let remote = connection.remoteObjectProxyWithErrorHandler({ error in
            finish(.success(.unreachable(error.localizedDescription)))
        }) as? PaprikaHelperProtocol else {
            finish(.success(.unreachable(L.s("프록시 생성 실패", "proxy creation failed"))))
            return
        }
        remote.handshake { version, protocolVersion in
            finish(.success(.ready(version: version, protocolVersion: protocolVersion)))
        }
    }

    public func fetchSnapshot(completion: @escaping (Result<PaprikaSnapshot, Error>) -> Void) {
        let finish = guarded(completion)
        guard let remote = proxy(finish) else { return }
        remote.fetchSnapshot { data, errorMessage in
            self.decodeReply(PaprikaSnapshot.self, data: data, errorMessage: errorMessage, finish: finish)
        }
    }

    public func update(config: PaprikaConfig, completion: @escaping (Result<PaprikaSnapshot, Error>) -> Void) {
        let finish = guarded(completion)
        guard let remote = proxy(finish) else { return }
        let payload: Data
        do {
            payload = try PaprikaCoding.encode(config)
        } catch {
            finish(.failure(HelperClientError.decoding(String(describing: error))))
            return
        }
        remote.updateConfig(payload) { data, errorMessage in
            self.decodeReply(PaprikaSnapshot.self, data: data, errorMessage: errorMessage, finish: finish)
        }
    }

    public func perform(
        _ command: PaprikaCommand,
        payload: Data? = nil,
        completion: @escaping (Result<PaprikaSnapshot, Error>) -> Void
    ) {
        let finish = guarded(completion)
        guard let remote = proxy(finish) else { return }
        remote.performCommand(command.rawValue, payload: payload) { data, errorMessage in
            self.decodeReply(PaprikaSnapshot.self, data: data, errorMessage: errorMessage, finish: finish)
        }
    }

    public func smcDump(includeAllKeys: Bool, completion: @escaping (Result<SMCDump, Error>) -> Void) {
        // 전체 키 열거는 느리다. 이 호출만 타임아웃을 넉넉히 준다.
        let hasFired = AtomicFlag()
        let queue = completionQueue
        let finish: (Result<SMCDump, Error>) -> Void = { result in
            guard hasFired.trySet() else { return }
            queue.async { completion(result) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + (includeAllKeys ? 60 : 10)) {
            guard hasFired.trySet() else { return }
            queue.async { completion(.failure(HelperClientError.timeout)) }
        }
        guard let remote = proxy(finish) else { return }
        remote.smcDump(includeAllKeys: includeAllKeys) { data, errorMessage in
            self.decodeReply(SMCDump.self, data: data, errorMessage: errorMessage, finish: finish)
        }
    }

    public func restoreAndExit(completion: @escaping (Result<Void, Error>) -> Void) {
        let finish = guarded(completion)
        guard let remote = proxy(finish) else { return }
        remote.restoreAndExit { errorMessage in
            if let errorMessage {
                finish(.failure(HelperClientError.remote(errorMessage)))
            } else {
                finish(.success(()))
            }
        }
    }
}

/// "한 번만 실행" 보장을 위한 아주 작은 도구.
private final class AtomicFlag {
    private var value = false
    private let lock = NSLock()

    /// 아직 설정되지 않았으면 true 를 돌려주고 설정한다.
    func trySet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}
