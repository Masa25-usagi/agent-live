import Foundation
import AgentServices
@preconcurrency import AVFoundation
import CoreImage

// Explicit integration check: only caller-supplied synthetic fixtures are uploaded.
// Unverified files stay in the caller's private scratch directory on failure.
struct Pairing: Decodable { let endpoint: String; let token: String }
final class VideoFiles: @unchecked Sendable {
    private let lock = NSLock(); private var files: [URL] = []
    func append(_ url: URL) { lock.withLock { files.append(url) } }
    var all: [URL] { lock.withLock { files } }
}
let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    print("Usage: AgentDriveChecks /private/pairing.json /private/synthetic.wav /private/scratch"); exit(2)
}
var report: [String: Bool] = [:]
do {
    let pairing = try JSONDecoder().decode(Pairing.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
    let fixture = URL(fileURLWithPath: arguments[2]), scratch = URL(fileURLWithPath: arguments[3])
    let bridge = try BridgeClient(endpoint: pairing.endpoint, token: pairing.token)
    let id = "drive-check-" + UUID().uuidString
    let archive = try RecordingArchive(root: scratch.appendingPathComponent(id))
    try archive.start(sessionID: id)
    try archive.appendTranscript(text: "これは合成音声・映像を使ったDrive保存の接続試験です。", source: "fixture", final: true)
    try archive.finish()
    let copy = archive.root.appendingPathComponent("fixture.wav")
    try FileManager.default.copyItem(at: fixture, to: copy)
    try archive.importFile(copy, sessionID: id, kind: "audio", source: "microphone", mimeType: "audio/wav", startedAt: Date(), duration: 8)
    let videos = VideoFiles()
    let encoder = try VideoSegmentEncoder(directory: archive.root.appendingPathComponent("VideoStaging"), onSegment: { url, _, _ in videos.append(url) }, onError: { _ in })
    var pixel: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess, let pixel else { throw ArchiveError.invalidAudio }
    CIContext().render(CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.8)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180)), to: pixel)
    for index in 0..<30 { encoder.append(pixel, at: CMTime(seconds: Double(index) / 15, preferredTimescale: 600)) }
    await withCheckedContinuation { continuation in encoder.finish { continuation.resume() } }
    guard let video = videos.all.first else { throw ArchiveError.invalidAudio }
    try archive.importFile(video, sessionID: id, kind: "video", source: "screen", mimeType: "video/mp4", startedAt: Date(), duration: 2)
    let originals = archive.inventory
    report["originals_retained_before_confirmation"] = originals.count == 3 && originals.allSatisfy { FileManager.default.fileExists(atPath: archive.file(for: $0).path) && !$0.cloudVerified }
    _ = try await bridge.json("sessions/" + id + "/finish", method: "POST", body: ["items": originals.map(\.id)])
    let deadline = Date().addingTimeInterval(120)
    while Date() < deadline && !archive.pending().isEmpty {
        _ = try await bridge.synchronize(archive)
        if !archive.pending().isEmpty { try await Task.sleep(for: .seconds(2)) }
    }
    report["native_cloud_receipts_verified"] = archive.inventory.allSatisfy { $0.cloudVerified && !($0.cloudFileID ?? "").isEmpty }
    report["confirmed_local_files_removed"] = archive.pendingBytes == 0 && archive.inventory.allSatisfy { $0.localRemoved && !FileManager.default.fileExists(atPath: archive.file(for: $0).path) }
    guard let audio = archive.inventory.first(where: { $0.kind == "audio" }) else { throw ArchiveError.invalidAudio }
    var request = bridge.request("archive/" + audio.id, method: "PUT")
    request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
    request.setValue(try JSONEncoder().encode(audio).base64EncodedString(), forHTTPHeaderField: "X-Archive-Metadata")
    let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fixture)
    let receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    report["same_id_retry_reuses_cloud_file"] = (response as? HTTPURLResponse)?.statusCode == 200 && receipt?["cloud_file_id"] as? String == audio.cloudFileID
    var minutes: [String: Any] = [:]
    let minutesDeadline = Date().addingTimeInterval(120)
    while Date() < minutesDeadline {
        minutes = try await bridge.json("sessions/" + id + "/finish", method: "POST", body: ["items": originals.map(\.id)])
        if minutes["status"] as? String == "completed" { break }
        try await Task.sleep(for: .seconds(3))
    }
    report["minutes_created"] = minutes["status"] as? String == "completed" && !(minutes["minutes"] as? String ?? "").isEmpty
    let record = try await bridge.json("sessions/" + id)
    report["japanese_transcript_created"] = (record["entries"] as? [[String: Any]] ?? []).contains { ($0["text"] as? String ?? "").contains("議事録") }
    let evidence: [String: Any] = ["session": id, "items": originals.map(\.id), "checks": report]
    try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: scratch.appendingPathComponent("probe.json"), options: .atomic)
    print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
} catch { print("Drive integration check did not complete. Unconfirmed originals are retained."); exit(1) }
exit(report.values.allSatisfy { $0 } ? 0 : 1)
