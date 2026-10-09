import Foundation
import AVFoundation
import CoreImage

/// H.264 media is sealed every 20 seconds; Live receives only a sampled JPEG view.
public final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public var onFrame: ((Data) -> Void)?
    public var onSegment: ((URL, Date, Double) -> Void)?
    public var onError: ((String) -> Void)?
    private let queue = DispatchQueue(label: "agent-live.camera")
    private let context = CIContext()
    private var session: AVCaptureSession?
    private var encoder: VideoSegmentEncoder?
    private var lastFrame = Date.distantPast
    private let stateLock = NSLock()
    private var generation = UUID()
    public func start(directory: URL, recordVideo: Bool) async throws {
        let token = stateLock.withLock { generation }
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw NSError(domain: "Camera", code: 1, userInfo: [NSLocalizedDescriptionKey: "カメラの使用を許可してください。音声の記録は続けられます。"]) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard self.stateLock.withLock({ self.generation == token }) else { throw CancellationError() }
                    if self.session != nil { continuation.resume(); return }
                    let session = AVCaptureSession()
                    session.beginConfiguration(); session.sessionPreset = .vga640x480
                    guard let camera = AVCaptureDevice.default(for: .video) else { throw NSError(domain: "Camera", code: 2) }
                    let input = try AVCaptureDeviceInput(device: camera)
                    guard session.canAddInput(input) else { throw NSError(domain: "Camera", code: 3) }
                    session.addInput(input)
                    let output = AVCaptureVideoDataOutput(); output.alwaysDiscardsLateVideoFrames = true
                    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    output.setSampleBufferDelegate(self, queue: self.queue)
                    guard session.canAddOutput(output) else { throw NSError(domain: "Camera", code: 4) }
                    session.addOutput(output); session.commitConfiguration()
                    if recordVideo { self.encoder = try VideoSegmentEncoder(directory: directory, onSegment: self.onSegment ?? { _, _, _ in }, onError: { [weak self] in self?.onError?($0) }) }
                    self.session = session; session.startRunning(); continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    public func stop() async {
        stateLock.withLock { generation = UUID() }
        await withCheckedContinuation { continuation in
            queue.async {
                self.session?.stopRunning(); self.session = nil
                if let encoder = self.encoder { self.encoder = nil; encoder.finish { continuation.resume() } }
                else { continuation.resume() }
            }
        }
    }
    public func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixel = CMSampleBufferGetImageBuffer(buffer) else { return }
        encoder?.append(pixel, at: CMSampleBufferGetPresentationTimeStamp(buffer))
        guard Date().timeIntervalSince(lastFrame) >= 1 else { return }; lastFrame = Date()
        if let data = context.jpegRepresentation(of: CIImage(cvPixelBuffer: pixel), colorSpace: CGColorSpaceCreateDeviceRGB(), options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.6]) { onFrame?(data) }
    }
}

/// Single-queue encoder. Its .part files never enter the upload inventory before finalization.
public final class VideoSegmentEncoder: @unchecked Sendable {
    private let directory: URL
    private let onSegment: (URL, Date, Double) -> Void
    private let onError: (String) -> Void
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var start = CMTime.zero
    private var last = CMTime.zero
    private var began = Date()
    private var url: URL?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let finalizations = DispatchGroup()
    private var lastEncoded = CMTime.invalid
    public init(directory: URL, onSegment: @escaping (URL, Date, Double) -> Void, onError: @escaping (String) -> Void) throws {
        self.directory = directory; self.onSegment = onSegment; self.onError = onError
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    public func append(_ pixel: CVPixelBuffer, at time: CMTime) {
        guard time.isValid, time.isNumeric else { return }
        if lastEncoded.isValid, CMTimeGetSeconds(time - lastEncoded) < 1.0 / 15 { return }
        lastEncoded = time
        if writer != nil, CMTimeGetSeconds(time - start) >= 20 { finish() }
        if writer == nil {
            do {
                let staged = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]).reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
                guard staged < 128 * 1_024 * 1_024 else { throw ArchiveError.full }
                let url = directory.appendingPathComponent(UUID().uuidString + ".mp4")
                let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                let factor = min(1.0, 720.0 / Double(max(CVPixelBufferGetWidth(pixel), CVPixelBufferGetHeight(pixel))))
                let width = max(2, Int(Double(CVPixelBufferGetWidth(pixel)) * factor) / 2 * 2)
                let height = max(2, Int(Double(CVPixelBufferGetHeight(pixel)) * factor) / 2 * 2)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 600_000, AVVideoExpectedSourceFrameRateKey: 15]])
                input.expectsMediaDataInRealTime = true
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
                guard writer.canAdd(input) else { throw NSError(domain: "VideoEncoder", code: 1) }; writer.add(input)
                guard writer.startWriting() else { throw writer.error ?? NSError(domain: "VideoEncoder", code: 2) }
                writer.startSession(atSourceTime: time)
                self.writer = writer; self.input = input; self.adaptor = adaptor; self.url = url; self.start = time; self.began = Date()
            } catch { onError("映像を保存できませんでした。音声の記録は続けています。"); return }
        }
        last = time
        guard input?.isReadyForMoreMediaData == true, let adaptor, let pool = adaptor.pixelBufferPool else { return }
        var resized: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &resized) == kCVReturnSuccess, let resized else { return }
        let image = CIImage(cvPixelBuffer: pixel)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: Double(CVPixelBufferGetWidth(resized)) / image.extent.width, y: Double(CVPixelBufferGetHeight(resized)) / image.extent.height))
        context.render(scaled, to: resized)
        if !adaptor.append(resized, withPresentationTime: time) { onError("映像の保存先を確認してください。") }
    }
    public func finish(completion: @escaping () -> Void = {}) {
        guard let writer, let input, let url else { finalizations.notify(queue: .global(), execute: completion); return }
        let began = self.began, duration = max(0, CMTimeGetSeconds(last - start))
        let onSegment = self.onSegment, onError = self.onError
        self.writer = nil; self.input = nil; self.adaptor = nil; self.url = nil
        finalizations.enter()
        input.markAsFinished()
        let finalizations = self.finalizations
        writer.finishWriting {
            if writer.status == .completed { onSegment(url, began, duration) }
            else { onError("映像の最終保存を完了できませんでした。ファイルは端末に残しています。") }
            finalizations.leave()
        }
        finalizations.notify(queue: .global(), execute: completion)
    }
}
