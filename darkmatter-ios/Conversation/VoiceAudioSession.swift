import AVFoundation

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
    static func configureForPlayback(
        _ session: VoiceAudioSessionConfiguring = AVAudioSession.sharedInstance()
    ) throws {
        try session.setCategory(.playback, mode: .spokenAudio, options: [])
        try session.setActive(true, options: [])
    }

    static func configureForRecording(
        _ session: VoiceAudioSessionConfiguring = AVAudioSession.sharedInstance()
    ) throws {
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.allowBluetoothHFP, .defaultToSpeaker]
        )
        try session.setActive(true, options: [])
    }

    static func deactivate(
        _ session: VoiceAudioSessionConfiguring = AVAudioSession.sharedInstance()
    ) {
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
