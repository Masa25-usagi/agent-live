import Foundation
@preconcurrency import AVFoundation

/// Providers may return WAV or MP3. Preserve the container when saving and decoding.
public enum EncodedSpeechAudio {
    private static func isWave(_ data: Data) -> Bool {
        data.count >= 12 && data.prefix(4) == Data("RIFF".utf8) && data.dropFirst(8).prefix(4) == Data("WAVE".utf8)
    }
    public static func fileExtension(for data: Data) -> String { isWave(data) ? "wav" : "mp3" }
    public static func mimeType(for data: Data) -> String { isWave(data) ? "audio/wav" : "audio/mpeg" }

    /// Decode to the mono 24 kHz PCM16 used by the shared voice-processing engine.
    public static func decode(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= 16 * 1024 * 1024 else { throw ArchiveError.invalidAudio }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + fileExtension(for: data))
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard rate > 0, file.length > 0, Double(file.length) / rate < 180,
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(ceil(Double(file.length) * 24_000 / rate) + 32)) else { throw ArchiveError.invalidAudio }
        try file.read(into: source)
        var supplied = false, conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return source
        }
        if let conversionError { throw conversionError }
        guard output.frameLength > 0, let samples = output.int16ChannelData?[0] else { throw ArchiveError.invalidAudio }
        return Data(bytes: samples, count: Int(output.frameLength) * 2)
    }
}
