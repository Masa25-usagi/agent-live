import Foundation

/// Same conservative PCM gate as the bridge: 300 ms lead-in and 1.2 s trailing silence.
/// Nil marks audioStreamEnd. This is an energy gate; provider VAD still detects actual speech.
public struct DeviceSilenceGate {
    private var lead = Data()
    private var active = false
    private var quietBytes = 0
    public init() {}
    public mutating func feed(_ pcm: Data) -> [Data?] {
        guard pcm.count % 2 == 0 else { return [] }
        var output: [Data?] = [], pending = Data()
        for offset in stride(from: 0, to: pcm.count, by: 640) {
            let frame = pcm.subdata(in: offset..<min(offset + 640, pcm.count))
            let quiet = frame.withUnsafeBytes { raw in
                var maximum = 0, squares: Int64 = 0
                for index in stride(from: 0, to: frame.count, by: 2) {
                    let sample = Int(raw.loadUnaligned(fromByteOffset: index, as: Int16.self).littleEndian)
                    maximum = max(maximum, abs(sample)); squares += Int64(sample) * Int64(sample)
                }
                return maximum < 64 && squares < Int64(frame.count / 2) * 256
            }
            if !quiet {
                if !active { pending.append(lead); lead.removeAll(keepingCapacity: true) }
                active = true; quietBytes = 0; pending.append(frame)
            } else if active {
                pending.append(frame); quietBytes += frame.count
                if quietBytes >= 38_400 {
                    if !pending.isEmpty { output.append(pending); pending.removeAll(keepingCapacity: true) }
                    output.append(nil); active = false; quietBytes = 0
                }
            } else {
                lead.append(frame)
                if lead.count > 9_600 { lead.removeFirst(lead.count - 9_600) }
            }
        }
        if !pending.isEmpty { output.append(pending) }
        return output
    }
}
