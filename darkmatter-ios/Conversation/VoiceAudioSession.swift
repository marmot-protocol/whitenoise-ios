import AVFoundation
import Foundation

protocol VoiceAudioSessionConfiguring: AnyObject {
    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

extension AVAudioSession: VoiceAudioSessionConfiguring {}

enum VoiceAudioSession {
    final class Lease {
        fileprivate let id = UUID()
        fileprivate weak var session: VoiceAudioSessionConfiguring?
        fileprivate let sessionIdentifier: ObjectIdentifier

        fileprivate init(session: VoiceAudioSessionConfiguring) {
            self.session = session
            self.sessionIdentifier = ObjectIdentifier(session)
        }
    }

    private static let lock = NSLock()
    private static var activeLeaseIDsBySession: [ObjectIdentifier: Set<UUID>] = [:]

    @discardableResult
    static func configureForPlayback(
        _ session: VoiceAudioSessionConfiguring = AVAudioSession.sharedInstance()
    ) throws -> Lease {
        try session.setCategory(.playback, mode: .spokenAudio, options: [])
        try session.setActive(true, options: [])
        return activate(session)
    }

    @discardableResult
    static func configureForRecording(
        _ session: VoiceAudioSessionConfiguring = AVAudioSession.sharedInstance()
    ) throws -> Lease {
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.allowBluetoothHFP, .defaultToSpeaker]
        )
        try session.setActive(true, options: [])
        return activate(session)
    }

    static func deactivate(_ lease: Lease?) {
        guard let lease else { return }
        guard release(lease), let session = lease.session else { return }
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private static func activate(_ session: VoiceAudioSessionConfiguring) -> Lease {
        let lease = Lease(session: session)
        lock.lock()
        activeLeaseIDsBySession[lease.sessionIdentifier, default: []].insert(lease.id)
        lock.unlock()
        return lease
    }

    private static func release(_ lease: Lease) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard var leaseIDs = activeLeaseIDsBySession[lease.sessionIdentifier],
              leaseIDs.remove(lease.id) != nil
        else { return false }

        guard !leaseIDs.isEmpty else {
            activeLeaseIDsBySession.removeValue(forKey: lease.sessionIdentifier)
            return true
        }

        activeLeaseIDsBySession[lease.sessionIdentifier] = leaseIDs
        return false
    }
}
