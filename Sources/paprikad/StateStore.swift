//
//  StateStore.swift
//  paprikad
//
//  /Library/Application Support/Paprika/state.json 읽기/쓰기.
//  데몬이 재시작되거나 맥이 재부팅돼도 설정과 진행 상태가 이어지게 한다.
//

import Foundation
import PaprikaKit

final class StateStore {
    private let directory: String
    private let file: String

    init(
        directory: String = PaprikaPaths.daemonSupportDirectory,
        file: String = PaprikaPaths.daemonStateFile
    ) {
        self.directory = directory
        self.file = file
    }

    func load() -> DaemonState {
        guard let data = FileManager.default.contents(atPath: file) else {
            PaprikaLog.daemon.notice("저장된 상태가 없어 기본값으로 시작합니다.")
            return DaemonState()
        }
        do {
            var state = try PaprikaCoding.decode(DaemonState.self, from: data)
            state.config = state.config.sanitized()
            return state
        } catch {
            PaprikaLog.daemon.error("상태 파일을 읽지 못했습니다(기본값 사용): \(String(describing: error), privacy: .public)")
            return DaemonState()
        }
    }

    func save(_ incoming: DaemonState) {
        var state = incoming
        state.savedAt = Date()
        do {
            try ensureDirectory()
            let data = try PaprikaCoding.encode(state, prettyPrinted: true)
            let url = URL(fileURLWithPath: file)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: file
            )
        } catch {
            PaprikaLog.daemon.error("상태 저장 실패: \(String(describing: error), privacy: .public)")
        }
    }

    private func ensureDirectory() throws {
        guard !FileManager.default.fileExists(atPath: directory) else { return }
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o755))]
        )
    }
}
