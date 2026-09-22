//
//  HistoryStore.swift
//  Paprika
//
//  충전량/온도/전력 기록을 JSONL 로 남긴다. 한 줄에 한 샘플이라 append 가 싸고,
//  중간에 앱이 죽어도 마지막 줄만 버리면 된다.
//
//  ~/Library/Application Support/Paprika/history.jsonl
//

import Foundation
import PaprikaKit

struct HistorySample: Codable, Identifiable, Equatable {
    var date: Date
    var percent: Double
    var isCharging: Bool
    var isPluggedIn: Bool
    var limit: Int
    var temperature: Double?
    var batteryWatts: Double?

    var id: Date { date }
}

final class HistoryStore {

    private let fileURL: URL
    private let directoryURL: URL
    private let queue = DispatchQueue(label: "com.paprika.app.history", qos: .utility)

    init(path: String = PaprikaPaths.historyFile) {
        fileURL = URL(fileURLWithPath: path)
        directoryURL = fileURL.deletingLastPathComponent()
    }

    // MARK: 쓰기

    func append(_ sample: HistorySample) {
        queue.async { [self] in
            guard let line = encodeLine(sample) else { return }
            do {
                try ensureFile()
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                PaprikaLog.app.error("히스토리 기록 실패: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func encodeLine(_ sample: HistorySample) -> Data? {
        guard var data = try? PaprikaCoding.encode(sample) else { return nil }
        data.append(0x0A)  // \n
        return data
    }

    private func ensureFile() throws {
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    // MARK: 읽기

    /// 최근 `days` 일치 샘플을 시간순으로 돌려준다.
    func load(days: Int, completion: @escaping ([HistorySample]) -> Void) {
        queue.async { [self] in
            let samples = loadSync(days: days)
            DispatchQueue.main.async { completion(samples) }
        }
    }

    private func loadSync(days: Int) -> [HistorySample] {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let decoder = PaprikaCoding.decoder()

        var samples: [HistorySample] = []
        // 큰 파일에서도 메모리를 아끼려고 줄 단위로 훑는다.
        data.split(separator: 0x0A).forEach { lineData in
            guard !lineData.isEmpty,
                  let sample = try? decoder.decode(HistorySample.self, from: Data(lineData)),
                  sample.date >= cutoff
            else { return }
            samples.append(sample)
        }
        return samples.sorted { $0.date < $1.date }
    }

    // MARK: 정리

    /// 보관 기간이 지난 줄을 버린다.
    func prune(retentionDays: Int) {
        queue.async { [self] in
            let kept = loadSync(days: retentionDays)
            guard !kept.isEmpty else { return }
            var output = Data()
            for sample in kept {
                if let line = encodeLine(sample) { output.append(line) }
            }
            do {
                try ensureFile()
                try output.write(to: fileURL, options: .atomic)
            } catch {
                PaprikaLog.app.error("히스토리 정리 실패: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func deleteAll(completion: @escaping () -> Void) {
        queue.async { [self] in
            try? FileManager.default.removeItem(at: fileURL)
            DispatchQueue.main.async { completion() }
        }
    }

    var fileSizeBytes: Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? Int
        else { return 0 }
        return size
    }
}
