import AVFAudio
import Foundation

/// One synchronous, read-only borrow of the encoder's reusable PCM storage. The encoder's
/// serial owner cannot mutate that storage until `convert` returns, although SDK 26 imports
/// its input callback as escaping and Sendable. The lock only protects the reference's
/// exactly-once removal; the holder never changes samples and is cleared before the owner
/// resumes. This does not make the encoder or arbitrary mutable audio buffers Sendable.
final class APACConverterInput: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer?) { pending = buffer }

    func take() -> AVAudioPCMBuffer? {
        lock.withLock {
            defer { pending = nil }
            return pending
        }
    }

    func clear() { lock.withLock { pending = nil } }
}
