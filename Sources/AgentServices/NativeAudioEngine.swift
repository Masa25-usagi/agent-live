import Foundation
@preconcurrency import AVFoundation
import MeetingLive

/// Capture and playback share the voice-processing unit so speaker output has an echo reference.
public final class NativeAudioEngine: @unchecked Sendable {
    public var onPCM: ((Data, Float) -> Void)?
    public var onState: ((String) -> Void)?
    public var onCaptureState: ((AudioCaptureState) -> Void)?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private let converter = CapturePCMConverter()
    private var active = false
    private var capture = AudioCaptureLifecycle()
    private var tapInstalled = false
    private var playback = PCMPlaybackQueue()
    private var epoch = UUID()
    private var tokens: [NSObjectProtocol] = []
    private var encodedTask: Task<Void, Never>?
    private let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    public init() {
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
        #if os(iOS)
        tokens.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            Task { @MainActor in self.handleInterruption(type, shouldResume: options.contains(.shouldResume)) }
        })
        #endif
    }
    @MainActor public func start() async throws {
        guard !lock.withLock({ active }) else { return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw NSError(domain: "Microphone", code: 1, userInfo: [NSLocalizedDescriptionKey: "マイクの使用を許可してください。"]) }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setPreferredSampleRate(48_000); try session.setPreferredIOBufferDuration(0.02); try session.setActive(true)
        #endif
        try engine.inputNode.setVoiceProcessingEnabled(true)
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw NSError(domain: "Microphone", code: 2) }
        engine.inputNode.installTap(onBus: 0, bufferSize: 960, format: format) { [weak self] buffer, _ in self?.consume(buffer) }
        tapInstalled = true
        try engine.start(); lock.withLock { active = true }; player.play()
        capture.started(); onCaptureState?(capture.state)
    }
    #if os(iOS)
    @MainActor private func handleInterruption(_ type: AVAudioSession.InterruptionType, shouldResume: Bool) {
        guard lock.withLock({ active }) else { return }
        if type == .began, capture.interruptionBegan() {
            player.pause(); engine.pause(); onCaptureState?(capture.state)
            onState?("iOSが音声を一時停止しました。中断が終わると再開します。")
        } else if type == .ended, capture.state.paused {
            if capture.interruptionEnded(shouldResume: shouldResume) { resumeAfterInterruption() }
            else { onCaptureState?(capture.state); onState?("音声が停止しています。「音声を再開」を押してください。") }
        }
    }
    #endif
    @MainActor public func resumeAfterInterruption() {
        guard lock.withLock({ active }), capture.state.paused else { return }
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            if !engine.isRunning { try engine.start() }
            player.play(); capture.resumed(); onCaptureState?(capture.state)
        } catch { onCaptureState?(capture.state); onState?("音声を再開できませんでした。通話や音声を使う操作が終わってから、もう一度お試しください。") }
    }
    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard active, let data = converter.convert(buffer), !data.isEmpty else { return }
        let energy: Double = data.withUnsafeBytes { raw in
            var total = 0.0
            for i in stride(from: 0, to: data.count, by: 2) { let sample = Double(raw.loadUnaligned(fromByteOffset: i, as: Int16.self).littleEndian) / 32768; total += sample * sample }
            return total / Double(data.count / 2)
        }
        onPCM?(data, Float(min(1, sqrt(energy) * 5)))
    }
    @MainActor public func play(_ data: Data, rate: Double) {
        guard lock.withLock({ active }), rate == 24_000, data.count % 2 == 0, !data.isEmpty else { return }
        let duration = Double(data.count / 2) / rate
        guard playback.reserve(duration), let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(data.count / 2)), let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = buffer.frameCapacity
        data.withUnsafeBytes { bytes in for i in 0..<Int(buffer.frameLength) { samples[i] = Float(bytes.loadUnaligned(fromByteOffset: i * 2, as: Int16.self).littleEndian) / 32768 } }
        let token = epoch
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in Task { @MainActor in if self?.epoch == token { self?.playback.played(duration) } } }
        if engine.isRunning, !player.isPlaying { player.play() }
    }
    @MainActor public func playEncoded(_ data: Data) {
        let token = epoch
        let previous = encodedTask
        // Chunks can have different decode costs. Preserve their arrival order explicitly.
        encodedTask = Task { [weak self] in
            await previous?.value
            guard let self, self.epoch == token, !Task.isCancelled else { return }
            do {
                let pcm = try await Task.detached { try EncodedSpeechAudio.decode(data) }.value
                guard self.epoch == token, !Task.isCancelled else { return }
                self.play(pcm, rate: 24_000)
            } catch { if self.epoch == token { self.onState?("音声を再生できませんでした。返答は文字で残っています。") } }
        }
    }
    @MainActor public func interrupt() { epoch = UUID(); encodedTask?.cancel(); encodedTask = nil; player.stop(); playback.reset(); if lock.withLock({ active }), engine.isRunning { player.play() } }
    @MainActor public func stop() {
        lock.withLock { active = false }; interrupt()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine.stop()
        capture.stopped(); onCaptureState?(capture.state)
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
    deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
}

/// Use the mic clock (including silence). Mixing two PCM streams never doubles their duration.
public struct LiveInputMixer {
    private var remote = Data()
    public init() {}
    public mutating func appendRemote(_ data: Data) {
        guard data.count % 2 == 0 else { return }
        remote.append(data)
        if remote.count > 32_000 { remote = Data(remote.suffix(32_000)) }
    }
    public mutating func mixMicrophone(_ mic: Data) -> Data {
        guard mic.count % 2 == 0 else { return Data() }
        var output = Data(count: mic.count)
        let paired = min(mic.count, remote.count) / 2 * 2
        mic.withUnsafeBytes { input in remote.withUnsafeBytes { other in output.withUnsafeMutableBytes { target in
            for i in stride(from: 0, to: mic.count, by: 2) {
                let a = Int32(input.loadUnaligned(fromByteOffset: i, as: Int16.self).littleEndian)
                let b = i < paired ? Int32(other.loadUnaligned(fromByteOffset: i, as: Int16.self).littleEndian) : 0
                target.storeBytes(of: Int16(clamping: i < paired ? (a + b) / 2 : a).littleEndian, toByteOffset: i, as: Int16.self)
            }
        } } }
        remote.removeFirst(paired); return output
    }
}
