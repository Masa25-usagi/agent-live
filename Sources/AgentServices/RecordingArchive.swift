import Foundation
import CryptoKit

public struct ArchiveItem: Codable, Identifiable, Sendable {
    public var id: String
    public var sessionID: String
    public var source: String
    public var kind: String
    public var filename: String
    public var mimeType: String
    public var startedAt: Date
    public var duration: Double
    public var bytes: Int
    public var sha256: String
    public var cloudFileID: String?
    public var cloudVerified = false
    public var localRemoved = false
}

public enum ArchiveError: LocalizedError {
    case full, noSession, invalidAudio, invalidReceipt
    public var errorDescription: String? {
        switch self {
        case .full: return "保存待ちの容量が上限に達しました。同期を回復するか、保存先を確認してください。"
        case .noSession: return "記録を開始してください。"
        case .invalidAudio: return "音声データの形式を確認してください。"
        case .invalidReceipt: return "保存確認が一致しないため、端末の記録を残しています。"
        }
    }
}

/// A durable journal is separate from the disposable low-latency voice queue.
/// Only sealed, checksum-verified cloud copies can be evicted.
public final class RecordingArchive: @unchecked Sendable {
    public let root: URL
    public var maximumPendingBytes = 512 * 1_024 * 1_024
    public var segmentSeconds: Double = 20
    private let lock = NSRecursiveLock()
    private var sessionID: String?
    private var writers: [String: AudioWriter] = [:]
    private var items: [ArchiveItem] = []
    private var textWriter: TextWriter?
    private var lastTranscriptSync = Date.distantPast

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let indexURL = root.appendingPathComponent("index.json")
        if FileManager.default.fileExists(atPath: indexURL.path) {
            items = try JSONDecoder().decode([ArchiveItem].self, from: Data(contentsOf: indexURL))
        }
        try recoverInterruptedAudio()
        try recoverInterruptedText()
        try recoverImportedFiles()
        for item in items where item.cloudVerified && !item.localRemoved {
            try verifyAndEvict(id: item.id, sha256: item.sha256, fileID: item.cloudFileID ?? "")
        }
    }

    public var inventory: [ArchiveItem] { lock.withLock { items } }
    public var pendingBytes: Int { lock.withLock { localBytes() + writers.values.reduce(0) { $0 + $1.count + 44 } + (textWriter?.count ?? 0) } }

    public func start(sessionID: String = UUID().uuidString) throws {
        try lock.withLock {
            if self.sessionID != nil { try finish() }
            self.sessionID = sessionID
        }
    }

    public func appendAudio(_ data: Data, source: String, sampleRate: Int = 16_000) throws {
        try lock.withLock {
            guard let sessionID else { throw ArchiveError.noSession }
            guard data.count % 2 == 0, sampleRate > 0 else { throw ArchiveError.invalidAudio }
            let key = "\(source):\(sampleRate)"
            let limit = max(2, Int(segmentSeconds * Double(sampleRate) * 2) / 2 * 2)
            let available = writers[key].map { max(0, limit - $0.count) } ?? 0
            let additionalWriters = max(0, data.count - available + limit - 1) / limit
            try checkCapacity(adding: data.count + additionalWriters * 44)
            var remaining = data[...]
            while !remaining.isEmpty {
                if writers[key] == nil { writers[key] = try newWriter(sessionID: sessionID, source: source, rate: sampleRate) }
                guard let writer = writers[key] else { throw ArchiveError.noSession }
                let length = min(remaining.count, limit - writer.count)
                try writer.handle.write(contentsOf: remaining.prefix(length))
                writer.count += length; remaining = remaining.dropFirst(length)
                if writer.count >= limit { try seal(writer); writers.removeValue(forKey: key) }
            }
        }
    }

    public func appendTranscript(text: String, source: String, final: Bool, eventID: String = UUID().uuidString) throws {
        try lock.withLock {
            guard let sessionID else { return }
            let row: [String: Any] = ["id": eventID, "timestamp": ISO8601DateFormatter().string(from: Date()), "source": source, "isFinal": final, "text": text]
            let json = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            let line = String(decoding: json, as: UTF8.self) + "\n"
            try checkCapacity(adding: line.utf8.count)
            if textWriter == nil {
                let info = TextRecovery(id: UUID().uuidString, sessionID: sessionID, startedAt: Date())
                try JSONEncoder().encode(info).write(to: root.appendingPathComponent(info.id + ".text-recovery.json"), options: .atomic)
                let url = root.appendingPathComponent(info.id + ".jsonl.part")
                try Data().write(to: url)
                textWriter = TextWriter(info: info, handle: try FileHandle(forWritingTo: url))
            }
            if let writer = textWriter {
                try writer.handle.write(contentsOf: Data(line.utf8))
                // Partial captions must not fsync every recognition callback on the UI thread.
                // Final text is durable immediately; partial hypotheses sync at least once a second.
                if final || Date().timeIntervalSince(lastTranscriptSync) >= 1 {
                    try writer.handle.synchronize(); lastTranscriptSync = Date()
                }
                writer.count += line.utf8.count
                if Date().timeIntervalSince(writer.info.startedAt) >= segmentSeconds { try sealTranscript() }
            }
        }
    }

    public func addFile(_ url: URL, kind: String, source: String, mimeType: String, startedAt: Date, duration: Double) throws {
        try lock.withLock {
            guard let sessionID else { throw ArchiveError.noSession }
            try importFile(url, sessionID: sessionID, kind: kind, source: source, mimeType: mimeType, startedAt: startedAt, duration: duration)
        }
    }

    public func importFile(_ url: URL, sessionID: String, kind: String, source: String, mimeType: String, startedAt: Date, duration: Double) throws {
        try lock.withLock {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let id = UUID().uuidString
            let name = id + "." + url.pathExtension
            let item = ArchiveItem(id: id, sessionID: sessionID, source: source, kind: kind, filename: name, mimeType: mimeType, startedAt: startedAt, duration: duration, bytes: size, sha256: try Self.digest(url))
            try adopt(item, from: url)
        }
    }

    /// Preserve the upload identifier when taking ownership from a ReplayKit extension.
    public func adopt(_ item: ArchiveItem, from url: URL) throws {
        try lock.withLock {
            guard item.filename == URL(fileURLWithPath: item.filename).lastPathComponent,
                  try Self.digest(url) == item.sha256 else { throw ArchiveError.invalidReceipt }
            if let existing = items.first(where: { $0.id == item.id }) {
                guard existing.sha256 == item.sha256, existing.sessionID == item.sessionID else { throw ArchiveError.invalidReceipt }
                return
            }
            try checkCapacity(adding: item.bytes)
            let recovery = root.appendingPathComponent(item.id + ".file-recovery.json")
            try JSONEncoder().encode(item).write(to: recovery, options: .atomic)
            try FileManager.default.moveItem(at: url, to: root.appendingPathComponent(item.filename))
            items.append(item); try save()
            try? FileManager.default.removeItem(at: recovery)
        }
    }

    public func finish() throws {
        try lock.withLock {
            for writer in writers.values { try seal(writer) }
            writers.removeAll(); try sealTranscript(); sessionID = nil
        }
    }

    public func sealDueSegments() throws {
        try lock.withLock {
            for (key, writer) in writers where Date().timeIntervalSince(writer.info.startedAt) >= segmentSeconds {
                try seal(writer); writers.removeValue(forKey: key)
            }
            if let textWriter, Date().timeIntervalSince(textWriter.info.startedAt) >= segmentSeconds { try sealTranscript() }
        }
    }

    public func pending() -> [ArchiveItem] { lock.withLock { items.filter { !$0.cloudVerified && !$0.localRemoved } } }
    public func file(for item: ArchiveItem) -> URL { root.appendingPathComponent(item.filename) }

    public func verifyAndEvict(id: String, sha256: String, fileID: String) throws {
        try lock.withLock {
            guard let index = items.firstIndex(where: { $0.id == id }), items[index].sha256 == sha256, !fileID.isEmpty else { throw ArchiveError.invalidReceipt }
            items[index].cloudFileID = fileID; items[index].cloudVerified = true
            // Persist the receipt before removing the original. A crash can only retain extra data.
            try save()
            let url = file(for: items[index])
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            items[index].localRemoved = true; try save()
        }
    }

    private func localBytes() -> Int { items.filter { !$0.localRemoved }.reduce(0) { $0 + $1.bytes } }
    private func checkCapacity(adding bytes: Int) throws {
        let unsealed = writers.values.reduce(0) { $0 + $1.count + 44 } + (textWriter?.count ?? 0)
        guard localBytes() + unsealed + bytes <= maximumPendingBytes else { throw ArchiveError.full }
        if let free = try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
           free < bytes + 64 * 1_024 * 1_024 { throw ArchiveError.full }
    }
    private func save() throws { try JSONEncoder().encode(items).write(to: root.appendingPathComponent("index.json"), options: .atomic) }
    private func newWriter(sessionID: String, source: String, rate: Int) throws -> AudioWriter {
        let id = UUID().uuidString
        let info = AudioRecovery(id: id, sessionID: sessionID, source: source, rate: rate, startedAt: Date())
        try JSONEncoder().encode(info).write(to: root.appendingPathComponent(id + ".recovery.json"), options: .atomic)
        let path = root.appendingPathComponent(id + ".wav.part")
        FileManager.default.createFile(atPath: path.path, contents: Self.wavHeader(bytes: 0, rate: rate))
        let handle = try FileHandle(forWritingTo: path); try handle.seekToEnd()
        return AudioWriter(info: info, handle: handle)
    }

    private func seal(_ writer: AudioWriter) throws {
        if !writer.closed {
            try writer.handle.seek(toOffset: 0)
            try writer.handle.write(contentsOf: Self.wavHeader(bytes: writer.count, rate: writer.info.rate))
            try writer.handle.synchronize(); try writer.handle.close(); writer.closed = true
        }
        try registerRecovered(writer.info, bytes: writer.count)
    }

    private func registerRecovered(_ info: AudioRecovery, bytes: Int) throws {
        let part = root.appendingPathComponent(info.id + ".wav.part")
        let name = info.id + ".wav", url = root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: part.path) { try FileManager.default.moveItem(at: part, to: url) }
        if bytes == 0 { try? FileManager.default.removeItem(at: url) }
        if !items.contains(where: { $0.id == info.id }), bytes > 0 {
            items.append(ArchiveItem(id: info.id, sessionID: info.sessionID, source: info.source, kind: "audio", filename: name, mimeType: "audio/wav", startedAt: info.startedAt, duration: Double(bytes) / Double(info.rate * 2), bytes: bytes + 44, sha256: try Self.digest(url)))
        }
        try save()
        try? FileManager.default.removeItem(at: root.appendingPathComponent(info.id + ".recovery.json"))
    }

    private func recoverInterruptedAudio() throws {
        for metadata in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where metadata.lastPathComponent.hasSuffix(".recovery.json") {
            guard let info = try? JSONDecoder().decode(AudioRecovery.self, from: Data(contentsOf: metadata)) else { continue }
            let part = root.appendingPathComponent(info.id + ".wav.part")
            if FileManager.default.fileExists(atPath: part.path) {
                let raw = (try part.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 44) - 44
                let count = max(0, raw / 2 * 2)
                let handle = try FileHandle(forWritingTo: part)
                try handle.truncate(atOffset: UInt64(count + 44)); try handle.seek(toOffset: 0)
                try handle.write(contentsOf: Self.wavHeader(bytes: count, rate: info.rate)); try handle.close()
                try registerRecovered(info, bytes: count)
            } else if FileManager.default.fileExists(atPath: root.appendingPathComponent(info.id + ".wav").path) {
                let count = max(0, (try root.appendingPathComponent(info.id + ".wav").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 44) - 44)
                try registerRecovered(info, bytes: count)
            }
        }
    }

    private func sealTranscript() throws {
        guard let writer = textWriter else { return }
        if !writer.closed { try writer.handle.synchronize(); try writer.handle.close(); writer.closed = true }
        try registerText(writer.info)
        textWriter = nil
    }

    private func registerText(_ info: TextRecovery) throws {
        let part = root.appendingPathComponent(info.id + ".jsonl.part")
        let name = info.id + ".jsonl", url = root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: part.path) { try FileManager.default.moveItem(at: part, to: url) }
        if FileManager.default.fileExists(atPath: url.path), !items.contains(where: { $0.id == info.id }) {
            let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            items.append(ArchiveItem(id: info.id, sessionID: info.sessionID, source: "timeline", kind: "transcript", filename: name, mimeType: "application/x-ndjson", startedAt: info.startedAt, duration: Date().timeIntervalSince(info.startedAt), bytes: bytes, sha256: try Self.digest(url)))
        }
        try save()
        try? FileManager.default.removeItem(at: root.appendingPathComponent(info.id + ".text-recovery.json"))
    }

    private func recoverInterruptedText() throws {
        for metadata in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where metadata.lastPathComponent.hasSuffix(".text-recovery.json") {
            if let info = try? JSONDecoder().decode(TextRecovery.self, from: Data(contentsOf: metadata)) { try registerText(info) }
        }
    }

    private func recoverImportedFiles() throws {
        for metadata in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where metadata.lastPathComponent.hasSuffix(".file-recovery.json") {
            if let item = try? JSONDecoder().decode(ArchiveItem.self, from: Data(contentsOf: metadata)), FileManager.default.fileExists(atPath: file(for: item).path) {
                if !items.contains(where: { $0.id == item.id }) { items.append(item); try save() }
                try? FileManager.default.removeItem(at: metadata)
            }
        }
    }

    public static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 65_536), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func wavHeader(bytes: Int, rate: Int) -> Data {
        var data = Data("RIFF".utf8)
        func u32(_ n: Int) { var value = UInt32(n).littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u16(_ n: Int) { var value = UInt16(n).littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        u32(bytes + 36); data.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16); data.append(Data("data".utf8)); u32(bytes)
        return data
    }
}

private struct AudioRecovery: Codable { var id: String; var sessionID: String; var source: String; var rate: Int; var startedAt: Date }
private final class AudioWriter { let info: AudioRecovery; let handle: FileHandle; var count = 0; var closed = false; init(info: AudioRecovery, handle: FileHandle) { self.info = info; self.handle = handle } }
private struct TextRecovery: Codable { let id: String; let sessionID: String; let startedAt: Date }
private final class TextWriter { let info: TextRecovery; let handle: FileHandle; var count = 0; var closed = false; init(info: TextRecovery, handle: FileHandle) { self.info = info; self.handle = handle } }
