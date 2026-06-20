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
        fileprivate let configuration: Configuration

        fileprivate init(session: VoiceAudioSessionConfiguring, configuration: Configuration) {
            self.session = session
            self.sessionIdentifier = ObjectIdentifier(session)
            self.configuration = configuration
        }
    }

    fileprivate struct Configuration {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }

    private enum ReleaseAction {
        case none
        case deactivate
        case restore(Configuration)
    }

    private static let lock = NSLock()
    private static var activeLeasesBySession: [ObjectIdentifier: [Lease]] = [:]

    @discardableResult
    static func configureForPlayback(
        _ session: VoiceAudioSessionConfiguring = AVAudioSession.sharedInstance()
    ) throws -> Lease {
        let configuration = Configuration(category: .playback, mode: .spokenAudio, options: [])
        try apply(configuration, to: session)
        try session.setActive(true, options: [])
        return activate(session, configuration: configuration)
    }

    @discardableResult
    static func configureForVideoPlayback(
        _ session: VoiceAudioSessionConfiguring = AVAudioSession.sharedInstance()
    ) throws -> Lease {
        let configuration = Configuration(category: .playback, mode: .moviePlayback, options: [])
        try apply(configuration, to: session)
        try session.setActive(true, options: [])
        return activate(session, configuration: configuration)
    }

    @discardableResult
    static func configureForRecording(
        _ session: VoiceAudioSessionConfiguring = AVAudioSession.sharedInstance()
    ) throws -> Lease {
        let configuration = Configuration(
            category: .playAndRecord,
            mode: .spokenAudio,
            options: [.allowBluetoothHFP, .defaultToSpeaker]
        )
        try apply(configuration, to: session)
        try session.setActive(true, options: [])
        return activate(session, configuration: configuration)
    }

    static func deactivate(_ lease: Lease?) {
        guard let lease else { return }
        let session = lease.session
        switch release(lease) {
        case .none:
            return
        case .deactivate:
            try? session?.setActive(false, options: [.notifyOthersOnDeactivation])
        case .restore(let configuration):
            guard let session else { return }
            try? apply(configuration, to: session)
        }
    }

    private static func apply(
        _ configuration: Configuration,
        to session: VoiceAudioSessionConfiguring
    ) throws {
        try session.setCategory(
            configuration.category,
            mode: configuration.mode,
            options: configuration.options
        )
    }

    private static func activate(
        _ session: VoiceAudioSessionConfiguring,
        configuration: Configuration
    ) -> Lease {
        let lease = Lease(session: session, configuration: configuration)
        lock.lock()
        activeLeasesBySession[lease.sessionIdentifier, default: []].append(lease)
        lock.unlock()
        return lease
    }

    private static func release(_ lease: Lease) -> ReleaseAction {
        lock.lock()
        defer { lock.unlock() }

        guard var leases = activeLeasesBySession[lease.sessionIdentifier],
              let index = leases.firstIndex(where: { $0.id == lease.id })
        else { return .none }

        let removedLastLease = index == leases.count - 1
        leases.remove(at: index)

        guard !leases.isEmpty else {
            activeLeasesBySession.removeValue(forKey: lease.sessionIdentifier)
            return .deactivate
        }

        activeLeasesBySession[lease.sessionIdentifier] = leases
        return removedLastLease ? .restore(leases[leases.count - 1].configuration) : .none
    }
}
