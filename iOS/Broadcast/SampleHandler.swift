import ReplayKit
import AVFoundation
import CoreImage
import Darwin
import AgentServices

final class SampleHandler: RPBroadcastSampleHandler {
    private var archive: RecordingArchive?
    private var bridge: BridgeClient?
    private var encoder: VideoSegmentEncoder?
    private var sessionID = ""
    private var lockFD: Int32 = -1
    private let queue = DispatchQueue(label: "agent-live.broadcast", autoreleaseFrequency: .workItem)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let audioConverter = CapturePCMConverter()
    private var lastFrame = Date.distantPast
    private var framePending = false
    private var frameInterval: Double = 3
    private let ingressLock = NSLock()
    private var videoQueued = false
    private var lastQueuedVideo = CMTime.invalid
    private var syncTask: Task<Void, Never>?
    private var controlTask: Task<Void, Never>?
    private var stopping = false
    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        do {
            let group = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AgentLive", isDirectory: true)
            try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
            lockFD = open(group.appendingPathComponent("broadcast.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw NSError(domain: "Broadcast", code: 2) }
            let config = SharedBroadcastStore.read("connection")
            guard let endpoint = config?["endpoint"] as? String, let token = config?["token"] as? String, let id = config?["sessionID"] as? String else { throw NSError(domain: "Broadcast", code: 3) }
            sessionID = id; bridge = try BridgeClient(endpoint: endpoint, token: token)
            let archive = try RecordingArchive(root: group.appendingPathComponent("BroadcastRecordings")); self.archive = archive
            archive.maximumPendingBytes = max(64, min(4096, config?["offlineMegabytes"] as? Int ?? 512)) * 1_024 * 1_024
            frameInterval = config?["frameInterval"] as? Double == 1 ? 1 : 3
            try archive.start(sessionID: id)
            if config?["recordVideo"] as? Bool == true {
                encoder = try VideoSegmentEncoder(directory: archive.root.appendingPathComponent("VideoStaging"), onSegment: { url, began, duration in try? archive.importFile(url, sessionID: id, kind: "video", source: "screen", mimeType: "video/mp4", startedAt: began, duration: duration) }, onError: { [weak self] message in self?.fail(message) })
            }
            syncTask = Task { [weak self] in
                while !Task.isCancelled {
                    if let self, let bridge = self.bridge, let archive = self.archive { try? archive.sealDueSegments(); _ = try? await bridge.synchronize(archive) }
                    if let self, !Task.isCancelled, !self.ingressLock.withLock({ self.stopping }) { self.saveState(active: true) }
                    do { try await Task.sleep(for: .seconds(5)) } catch { break }
                }
            }
            controlTask = Task { [weak self] in
                while !Task.isCancelled {
                    if let self {
                        self.saveState(active: true)
                        let selected = SharedBroadcastStore.read("connection")
                        if selected?["sessionID"] as? String != self.sessionID {
                            self.ingressLock.withLock { self.stopping = true }
                            self.syncTask?.cancel()
                            DispatchQueue.main.async { [weak self] in self?.fail("Agent Liveの記録が終了したため、画面共有を終了しました。") }
                            return
                        }
                    }
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                }
            }
        } catch { fail("Agent Liveで記録を開始してから、画面共有を始めてください。") }
    }
    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBuffer.isValid, !ingressLock.withLock({ stopping }) else { return }
        // ReplayKit extensions have a small memory allowance. Never queue full-resolution frames.
        if sampleBufferType == .video {
            let stamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let accepted = ingressLock.withLock { () -> Bool in
                guard !videoQueued, !lastQueuedVideo.isValid || CMTimeGetSeconds(stamp - lastQueuedVideo) >= 1.0 / 15 else { return false }
                videoQueued = true; lastQueuedVideo = stamp; return true
            }
            guard accepted else { return }
        }
        queue.async { [weak self] in
            guard let self else { return }
            defer { if sampleBufferType == .video { self.ingressLock.withLock { self.videoQueued = false } } }
            guard !self.ingressLock.withLock({ self.stopping }) else { return }
            switch sampleBufferType {
            case .video:
                guard let pixel = sampleBuffer.imageBuffer else { return }
                self.encoder?.append(pixel, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                guard !self.framePending, Date().timeIntervalSince(self.lastFrame) >= self.frameInterval, let bridge = self.bridge else { return }
                let image = CIImage(cvPixelBuffer: pixel)
                let factor = min(1, 1280 / max(image.extent.width, image.extent.height))
                let resized = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
                guard let jpeg = self.context.jpegRepresentation(of: resized, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.6]) else { return }
                self.lastFrame = Date(); self.framePending = true
                Task { [weak self] in
                    try? await bridge.sendFrame(jpeg, sessionID: self?.sessionID ?? "")
                    self?.queue.async { self?.framePending = false }
                }
            case .audioApp:
                guard let description = sampleBuffer.formatDescription, let format = AVAudioFormat(cmAudioFormatDescription: description) as AVAudioFormat?, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples)) else { return }
                buffer.frameLength = buffer.frameCapacity
                guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(buffer.frameLength), into: buffer.mutableAudioBufferList) == noErr, let pcm = self.audioConverter.convert(buffer) else { return }
                do { try self.archive?.appendAudio(pcm, source: "screen-audio") } catch { self.fail("画面共有の保存待ち容量が上限に達しました。元の記録は残っています。") }
            case .audioMic: break // The main app owns microphone capture and echo cancellation.
            @unknown default: break
            }
        }
    }
    override func broadcastPaused() { try? archive?.appendTranscript(text: "画面共有を一時停止", source: "screen", final: true) }
    override func broadcastResumed() { try? archive?.appendTranscript(text: "画面共有を再開", source: "screen", final: true) }
    override func broadcastFinished() {
        saveState(active: false)
        ingressLock.withLock { stopping = true }; controlTask?.cancel(); controlTask = nil
        let worker = syncTask; worker?.cancel(); syncTask = nil
        let settled = DispatchSemaphore(value: 0)
        Task { await worker?.value; settled.signal() }
        guard settled.wait(timeout: .now() + 2) == .success else { return }
        let done = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            guard let self else { done.signal(); return }
            if let encoder = self.encoder { self.encoder = nil; encoder.finish { done.signal() } } else { done.signal() }
        }
        // On timeout keep the ownership lock until the extension exits.
        guard done.wait(timeout: .now() + 5) == .success else { return }
        try? archive?.finish()
        if let archive, let bridge {
            let uploaded = DispatchSemaphore(value: 0)
            Task { _ = try? await bridge.synchronize(archive); uploaded.signal() }
            guard uploaded.wait(timeout: .now() + 3) == .success else { saveState(active: false); return }
        }
        saveState(active: false)
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
    }
    private func saveState(active: Bool) {
        try? SharedBroadcastStore.save(["active": active, "sessionID": sessionID, "heartbeat": Date().timeIntervalSince1970, "pending_bytes": archive?.pendingBytes ?? 0], name: "state")
    }
    private func fail(_ message: String) { finishBroadcastWithError(NSError(domain: "AgentLive.Broadcast", code: 1, userInfo: [NSLocalizedDescriptionKey: message])) }
}
