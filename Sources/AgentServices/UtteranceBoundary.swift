import Foundation

/// A stable caption also ends a turn when room noise keeps the energy detector open.
public struct UtteranceBoundary {
    public var fast: Bool
    public init(fast: Bool = false) { self.fast = fast }
    public var finalWait: TimeInterval { fast ? 0.2 : 0.35 }
    public func shouldEnd(age: TimeInterval, silence: TimeInterval, unchanged: TimeInterval, hasText: Bool) -> Bool {
        if age >= 20 { return true }
        if silence >= (fast ? 0.45 : 0.65), unchanged >= 0.2 { return true }
        return hasText && unchanged >= (fast ? 1.25 : 1.8)
    }
}

/// Speak complete sentences as they arrive, preserving order and avoiding tiny fragments.
public struct ReplySentences {
    private var pending = ""
    public init() {}
    public mutating func append(_ delta: String, final: Bool = false) -> [String] {
        pending += delta
        var result: [String] = []
        while let end = pending.firstIndex(where: { "。！？!?\n".contains($0) }) {
            let sentence = String(pending[...end]).trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeSubrange(...end)
            if !sentence.isEmpty { result.append(sentence) }
        }
        if final {
            let rest = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty { result.append(rest) }
            pending = ""
        }
        return result
    }
}
