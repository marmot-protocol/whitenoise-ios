import AudioToolbox
import AVFoundation
import Speech

/// Feed the recognizer one decoded buffer at a time directly from verified
/// attachment bytes. Transcribing never creates a second file containing the recording.
@available(iOS 26, *)
actor VoiceTranscriptionInput {
    private let decoder: Decoder
    private let format: AVAudioFormat

    init(data: Data, format: AVAudioFormat) throws {
        // AnalyzerInput requires signed 16-bit samples.
        guard format.commonFormat == .pcmFormatInt16, format.channelCount == 1 else { throw AttachmentReadError.unavailable }
        self.format = format
        decoder = try Decoder(data: data, format: format)
    }

    func next() throws -> AnalyzerInput? {
        try Task.checkCancellation()
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw AttachmentReadError.unavailable
        }
        buffer.frameLength = buffer.frameCapacity
        var frames = buffer.frameCapacity
        guard ExtAudioFileRead(decoder.audio, &frames, buffer.mutableAudioBufferList) == noErr else {
            throw AttachmentReadError.unavailable
        }
        guard frames > 0 else { return nil }
        buffer.frameLength = frames
        return AnalyzerInput(buffer: buffer)
    }

    private nonisolated final class Decoder {
        let bytes: NSData
        let file: AudioFileID
        let audio: ExtAudioFileRef

        init(data: Data, format: AVAudioFormat) throws {
            let bytes = data as NSData
            var file: AudioFileID?
            let status = AudioFileOpenWithCallbacks(Unmanaged.passUnretained(bytes).toOpaque(), { context, offset, count, buffer, read in
                guard offset >= 0 else { return kAudio_ParamError }
                let bytes = Unmanaged<NSData>.fromOpaque(context).takeUnretainedValue()
                let available = offset < bytes.length ? bytes.length - Int(offset) : 0
                let length = min(available, Int(count))
                if length > 0 { memcpy(buffer, bytes.bytes.advanced(by: Int(offset)), length) }
                read.pointee = UInt32(length)
                return noErr
            }, nil, { context in
                return Int64(Unmanaged<NSData>.fromOpaque(context).takeUnretainedValue().length)
            }, nil, 0, &file)
            guard status == noErr, let file else { throw AttachmentReadError.unavailable }
            var audio: ExtAudioFileRef?
            guard ExtAudioFileWrapAudioFileID(file, false, &audio) == noErr, let audio else {
                AudioFileClose(file)
                throw AttachmentReadError.unavailable
            }
            guard ExtAudioFileSetProperty(audio, kExtAudioFileProperty_ClientDataFormat,
                                          UInt32(MemoryLayout<AudioStreamBasicDescription>.size), format.streamDescription) == noErr else {
                ExtAudioFileDispose(audio)
                AudioFileClose(file)
                throw AttachmentReadError.unavailable
            }
            self.bytes = bytes
            self.file = file
            self.audio = audio
        }

        deinit {
            ExtAudioFileDispose(audio)
            AudioFileClose(file)
        }
    }
}
