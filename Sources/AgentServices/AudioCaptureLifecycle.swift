import Foundation

public enum AudioCaptureState: Sendable {
    case inactive, recording, interrupted, resumeRequired
    public var paused: Bool { self == .interrupted || self == .resumeRequired }
}

/// Permission dialogs before capture and late notifications after stop aren't recording interruptions.
public struct AudioCaptureLifecycle {
    public private(set) var state: AudioCaptureState = .inactive
    public init() {}
    public mutating func started() { state = .recording }
    public mutating func stopped() { state = .inactive }
    public mutating func interruptionBegan() -> Bool {
        guard state == .recording else { return false }
        state = .interrupted; return true
    }
    public mutating func interruptionEnded(shouldResume: Bool) -> Bool {
        guard state.paused else { return false }
        state = .resumeRequired
        return shouldResume
    }
    public mutating func resumed() { if state.paused { state = .recording } }
}
