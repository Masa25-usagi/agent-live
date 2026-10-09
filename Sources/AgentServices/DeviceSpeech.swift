import Foundation
import AVFoundation

/// Generate PCM locally and use the app's existing voice-processing player for echo cancellation.
@MainActor
public final class DeviceSpeech {
    private let synthesizer = AVSpeechSynthesizer()
    private var generation = UUID()
    private var currentContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    public init() {}
    public func cancel() { generation = UUID(); currentContinuation?.finish(throwing: CancellationError()); currentContinuation = nil; synthesizer.stopSpeaking(at: .immediate) }
    public func render(_ text: String, onPCM: (Data) throws -> Void) async throws {
        try Task.checkCancellation()
        guard let voice = AVSpeechSynthesisVoice(language: "ja-JP") else { throw BridgeError.malformedResponse }
        let token = UUID(); generation = token
        defer { if generation == token { cancel() } }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice; utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        let converter = CapturePCMConverter(sampleRate: 24_000), lock = NSLock()
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            currentContinuation = continuation
            let timeout = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                continuation.finish(throwing: BridgeError.malformedResponse)
            }
            continuation.onTermination = { [weak self] reason in
                timeout.cancel()
                if case .cancelled = reason { Task { @MainActor in if self?.generation == token { self?.cancel() } } }
            }
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { continuation.finish(throwing: BridgeError.malformedResponse); return }
                if pcm.frameLength == 0 { continuation.finish(); return }
                let data = lock.withLock { converter.convert(pcm) }
                guard let data else { continuation.finish(throwing: BridgeError.malformedResponse); return }
                if !data.isEmpty { continuation.yield(data) }
            }
        }
        var rendered = 0
        for try await data in stream {
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            try onPCM(data)
            rendered += data.count
        }
        try Task.checkCancellation()
        guard rendered > 0 else { throw BridgeError.malformedResponse }
    }
}
