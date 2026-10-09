import Foundation
import AVFoundation
import Speech

/// Captions and utterance boundaries are independent of archival chunks and network syncing.
/// Apple recognition is explicitly on-device; unavailable models fall back to archival Groq STT.
@MainActor
public final class ImmediateTranscriber {
    public var onText: ((String, String, Bool) -> Void)?
    public var onAvailability: ((Bool) -> Void)?
    public var fastMode = false
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timer: Task<Void, Never>?
    private var generation = UUID()
    private var utterance = UUID().uuidString
    private var text = ""
    private var started: TimeInterval = 0
    private var lastSpeech: TimeInterval = 0
    private var lastText: TimeInterval = 0
    private var ended: TimeInterval?
    private var preRoll = Data()
    private var pending = Data()
    private var failures = 0
    private var running = false
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    public init() {}

    public func start() async {
        stop(); let token = generation
        let granted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard generation == token, !Task.isCancelled else { return }
        guard granted, let value = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")), value.supportsOnDeviceRecognition, value.isAvailable else {
            onAvailability?(false); return
        }
        recognizer = value; running = true; failures = 0; onAvailability?(true)
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, self.generation == token, self.running else { return }
                let boundary = UtteranceBoundary(fast: self.fastMode)
                if let end = self.ended, self.now - end >= boundary.finalWait { self.complete() }
                else if self.request != nil, self.ended == nil,
                        boundary.shouldEnd(age: self.now - self.started, silence: self.now - self.lastSpeech, unchanged: self.now - self.lastText, hasText: !self.text.isEmpty) {
                    self.ended = self.now; self.request?.endAudio()
                }
            }
        }
    }
    public func append(_ pcm: Data) {
        guard running, pcm.count >= 2 else { return }
        let audible = pcm.withUnsafeBytes { bytes -> Bool in
            let values = bytes.bindMemory(to: Int16.self)
            guard !values.isEmpty else { return false }
            let energy = values.reduce(0.0) { $0 + pow(Double($1) / 32768, 2) }
            return sqrt(energy / Double(values.count)) > 0.008
        }
        if ended != nil {
            // Preserve new speech arriving while the previous task delivers its final hypothesis.
            pending.append(pcm); if pending.count > 64_000 { pending.removeFirst(pending.count - 64_000) }
            return
        }
        if request == nil {
            if !audible {
                preRoll.append(pcm); if preRoll.count > 9_600 { preRoll.removeFirst(preRoll.count - 9_600) }
                return
            }
            begin()
            feed(preRoll); preRoll.removeAll(keepingCapacity: true)
        }
        if audible { lastSpeech = now }
        feed(pcm)
    }
    private func begin() {
        guard running, let recognizer else { return }
        utterance = UUID().uuidString; text = ""; started = now; lastSpeech = now; lastText = now; ended = nil
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = ["Jev", "ジェブ", "Hermes", "ヘルメス", "Grok", "Nous Portal"]
        self.request = request
        let token = generation, id = utterance
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let update = result?.bestTranscription.formattedString, final = result?.isFinal == true
            Task { @MainActor in
                guard let self, self.running, self.generation == token, self.utterance == id, self.request != nil else { return }
                if let update, !update.isEmpty, update != self.text {
                    self.text = update; self.lastText = self.now; self.onText?(id, update, false)
                }
                if final { self.failures = 0; self.complete() }
                else if error != nil {
                    self.failures += 1; self.complete()
                    if self.failures >= 3 { self.stop(); self.onAvailability?(false) }
                }
            }
        }
    }
    private func feed(_ pcm: Data) {
        guard !pcm.isEmpty, let request, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count / 2)), let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = buffer.frameCapacity
        pcm.withUnsafeBytes { bytes in
            for (index, sample) in bytes.bindMemory(to: Int16.self).enumerated() { channel[index] = Float(sample) / 32768 }
        }
        request.append(buffer)
    }
    private func complete() {
        let id = utterance, final = text
        request?.endAudio(); request = nil; task?.cancel(); task = nil; text = ""; ended = nil
        if !final.isEmpty { onText?(id, final, true) }
        let buffered = pending; pending.removeAll(keepingCapacity: true)
        if !buffered.isEmpty { append(buffered) }
    }
    public func stop() {
        generation = UUID(); running = false
        timer?.cancel(); timer = nil; request?.endAudio(); task?.cancel(); task = nil; request = nil; recognizer = nil
        text = ""; preRoll.removeAll(); pending.removeAll(); ended = nil
    }
}
