import Foundation
import Combine
import AVFoundation
import CoreImage
import AgentServices
import MeetingCore

@MainActor
final class LiveMacController: ObservableObject {
    let session = AgentSession(automaticMaintenance: false)
    let capture = CaptureService()
    let audio = NativeAudioEngine()
    let camera = CameraCapture()
    @Published var cameraOn = false { didSet { if oldValue != cameraOn { if !cameraOn && !screenOn { session.clearVisualFrame() }; Task { await updateCamera() } } } }
    @Published var screenOn = false { didSet { if oldValue != screenOn { if !cameraOn && !screenOn { session.clearVisualFrame() }; scheduleCaptureUpdate() } } }
    @Published var selectedApplication: Int32 = 0 { didSet { if oldValue != selectedApplication { scheduleCaptureUpdate() } } }
    @Published var starting = false
    @Published var level: Float = 0
    @Published var captureError: String?
    private var subscriptions = Set<AnyCancellable>()
    private var screenEncoder: VideoSegmentEncoder?
    private var sourceTask: Task<Void, Never>?
    private let screenQueue = DispatchQueue(label: "agent-live.screen-video")
    private let imageContext = CIContext()
    init() {
        session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        capture.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        capture.onAudio = { [weak self] data, source in self?.session.acceptAudio(data, source: source) }
        capture.onFrame = { [weak self] jpeg in self?.receiveScreen(jpeg) }
        audio.onPCM = { [weak self] data, level in Task { @MainActor in self?.level = level; self?.session.acceptAudio(data) } }
        audio.onState = { [weak self] error in Task { @MainActor in self?.captureError = error } }
        session.onAudio = { [weak self] data, rate in self?.audio.play(data, rate: rate) }
        session.onEncodedAudio = { [weak self] data in self?.audio.playEncoded(data) }
        session.onInterrupt = { [weak self] in self?.audio.interrupt() }
        session.onStorageFull = { [weak self] in Task { await self?.stop() } }
        camera.onFrame = { [weak self] data in Task { @MainActor in if self?.cameraOn == true { self?.session.acceptFrame(data) } } }
        camera.onSegment = { [weak self] url, started, duration in Task { @MainActor in self?.session.acceptVideoFile(url, source: "camera", startedAt: started, duration: duration) } }
        camera.onError = { [weak self] error in Task { @MainActor in self?.captureError = error; self?.cameraOn = false } }
        Task {
            await capture.refreshApplications()
            let incoming = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AgentLive/Credentials/agentlive-pairing.json")
            if let data = try? Data(contentsOf: incoming), data.count <= 16_384,
               let config = try? JSONSerialization.jsonObject(with: data) as? [String: String], let token = config["token"], let endpoint = config["endpoint"] {
                await session.pair(token: String(decoding: data, as: UTF8.self))
                if DeviceCredential.read() == token && session.settings.endpoint == endpoint { try? FileManager.default.removeItem(at: incoming) }
            } else { await session.checkConnection() }
            session.startMaintenance()
        }
    }
    func start() async {
        guard !starting, !session.recording else { return }; starting = true; defer { starting = false }
        do {
            try await session.start()
            session.selectedAudioSource = .microphone
            session.mixMeetingAudio = selectedApplication != 0
            try await audio.start()
            await configureCapture()
            let sessionID = session.sessionID
            camera.onSegment = { [weak self] url, started, duration in Task { @MainActor in self?.session.acceptVideoFile(url, source: "camera", sessionID: sessionID, startedAt: started, duration: duration) } }
            if cameraOn { await updateCamera() }
        } catch { captureError = error.localizedDescription; await stop() }
    }
    func stop() async {
        sourceTask?.cancel(); await sourceTask?.value; sourceTask = nil
        audio.stop(); await capture.stop(); await camera.stop(); cameraOn = false
        await finishScreenVideo()
        await Task.yield(); await session.stop()
    }
    private func finishScreenVideo() async {
        if let encoder = screenEncoder {
            screenEncoder = nil
            await withCheckedContinuation { continuation in screenQueue.async { encoder.finish { continuation.resume() } } }
        }
    }
    private func scheduleCaptureUpdate() {
        guard session.recording else { return }
        let previous = sourceTask; previous?.cancel()
        sourceTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.session.recording else { return }
            await self.configureCapture()
        }
    }
    private func configureCapture() async {
        await finishScreenVideo(); await capture.stop()
        guard session.recording, !Task.isCancelled else { return }
        let app = selectedApplication, showScreen = screenOn, sessionID = session.sessionID
        session.mixMeetingAudio = app != 0
        guard app != 0 else { return }
        do {
            try await capture.start(applicationID: app, includeMicrophone: false, includeScreen: showScreen)
            guard session.recording, !Task.isCancelled else { await capture.stop(); return }
            if showScreen, session.settings.recordVideo {
                screenEncoder = try VideoSegmentEncoder(directory: session.archive.root.appendingPathComponent("VideoStaging"), onSegment: { [weak self] url, started, duration in Task { @MainActor in self?.session.acceptVideoFile(url, source: "screen", sessionID: sessionID, startedAt: started, duration: duration) } }, onError: { [weak self] error in Task { @MainActor in self?.captureError = error } })
            }
            try? session.archive.appendTranscript(text: showScreen ? "選択したアプリの音声と画面を共有" : "選択したアプリの音声を記録。画面共有は停止", source: "capture", final: true)
        } catch is CancellationError { }
        catch { captureError = error.localizedDescription }
    }
    private func updateCamera() async {
        guard cameraOn, session.recording else { await camera.stop(); return }
        do { try await camera.start(directory: session.archive.root.appendingPathComponent("VideoStaging"), recordVideo: session.settings.recordVideo) }
        catch is CancellationError { }
        catch { captureError = error.localizedDescription; cameraOn = false }
    }
    private func receiveScreen(_ jpeg: Data) {
        guard screenOn else { return }
        session.acceptFrame(jpeg)
        guard let encoder = screenEncoder else { return }
        let context = imageContext
        screenQueue.async {
            guard let image = CIImage(data: jpeg) else { return }
            var pixel: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, Int(image.extent.width), Int(image.extent.height), kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess, let pixel else { return }
            context.render(image, to: pixel)
            encoder.append(pixel, at: CMTime(seconds: ProcessInfo.processInfo.systemUptime, preferredTimescale: 600))
        }
    }
}
