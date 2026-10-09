import AVFoundation
import Foundation

/// The converter belongs to one capture queue and preserves resampling state between buffers.
public final class CapturePCMConverter {
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    public init(sampleRate: Double = 16_000) { outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: false)! }
    public func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return nil }
        if inputFormat != buffer.format { inputFormat = buffer.format; converter = AVAudioConverter(from: buffer.format, to: outputFormat); converter?.downmix = true }
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(ceil(Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate) + 32)) else { return nil }
        var provided = false, error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            if provided { status.pointee = .noDataNow; return nil }; provided = true; status.pointee = .haveData; return buffer
        }
        guard status != .error, error == nil, let samples = output.int16ChannelData?.pointee else { return nil }
        return Data(bytes: samples, count: Int(output.frameLength) * 2)
    }
}
