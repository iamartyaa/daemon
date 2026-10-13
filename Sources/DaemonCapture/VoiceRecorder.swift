import AVFoundation

/// Records a voice note to a temp .m4a and reports input levels (~20/s, 0...1) for the waveform toast.
@MainActor
final class VoiceRecorder {
    let url = CaptureFiles.newURL(ext: "m4a")
    private var recorder: AVAudioRecorder?
    private var meter: Timer?

    func start(onLevel: @escaping (Float) -> Void) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw CaptureFailed() }
        self.recorder = recorder
        meter = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                recorder.updateMeters()
                onLevel(Self.level(decibels: recorder.averagePower(forChannel: 0)))
            }
        }
    }

    func stop() -> URL {
        meter?.invalidate()
        recorder?.stop()
        recorder = nil
        return url
    }

    /// -50 dB and below is silence, 0 dB is full scale.
    nonisolated static func level(decibels: Float) -> Float {
        min(1, max(0, (decibels + 50) / 50))
    }
}
