import AVFoundation

extension Extractor {
    static let sampleRate = 16_000
    static let audioWindowMs = 60_000, audioHopMs = 55_000, videoWindowMs = 10_000

    /// 60 s windows of 16 kHz mono 16-bit WAV, starting every 55 s; the last one may be shorter.
    func audioDrafts(_ url: URL, itemId: Int64, workDir: URL) async throws -> [SegmentDraft] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ExtractError.unreadable(url) }
        return try audioWindows(asset, track: track, itemId: itemId, workDir: workDir)
    }

    /// One middle frame per 10 s window (modality `.video`), plus the audio track split like an audio file.
    func videoDrafts(_ url: URL, itemId: Int64, workDir: URL) async throws -> [SegmentDraft] {
        let asset = AVURLAsset(url: url)
        let hasVideo = !(try await asset.loadTracks(withMediaType: .video).isEmpty)
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        guard hasVideo || audioTrack != nil else { throw ExtractError.unreadable(url) }

        var drafts: [SegmentDraft] = []
        if hasVideo {
            let totalMs = Int(try await asset.load(.duration).seconds * 1000)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: Self.maxImageSide, height: Self.maxImageSide)
            for startMs in stride(from: 0, to: totalMs, by: Self.videoWindowMs) {
                let endMs = min(startMs + Self.videoWindowMs, totalMs)
                let middle = CMTime(value: Int64(startMs + endMs) / 2, timescale: 1000)
                // A frame that won't decode just leaves a gap; the rest of the video still gets indexed.
                guard let frame = try? await generator.image(at: middle).image,
                      let png = try? writePNG(frame, to: workDir) else { continue }
                let segment = Segment(itemId: itemId, modality: .video, startMs: startMs, endMs: endMs)
                drafts.append(SegmentDraft(segment: segment, input: .image(png)))
            }
        }
        if let audioTrack {
            drafts += try audioWindows(asset, track: audioTrack, itemId: itemId, workDir: workDir)
        }
        return drafts
    }

    private func audioWindows(_ asset: AVURLAsset, track: AVAssetTrack, itemId: Int64, workDir: URL) throws -> [SegmentDraft] {
        let samples = try pcm16kMono(asset, track: track)
        let perMs = Self.sampleRate / 1000
        let window = Self.audioWindowMs * perMs, hop = Self.audioHopMs * perMs
        var drafts: [SegmentDraft] = []
        var start = 0
        while start < samples.count {
            let end = min(start + window, samples.count)
            let wav = try writeWAV(samples[start..<end], to: workDir)
            let segment = Segment(itemId: itemId, modality: .audio, startMs: start / perMs, endMs: end / perMs)
            drafts.append(SegmentDraft(segment: segment, input: .audio(wav)))
            if end == samples.count { break }
            start += hop
        }
        return drafts
    }

    /// AVAssetReader decodes, downmixes and resamples in one pass, for audio files and video soundtracks alike.
    // ponytail: whole track in memory (~115 MB per hour); stream windows if multi-hour recordings show up.
    private func pcm16kMono(_ asset: AVURLAsset, track: AVAssetTrack) throws -> [Int16] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ExtractError.unreadable(asset.url) }

        var samples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Int16](repeating: 0, count: length / 2)
            _ = chunk.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            samples += chunk
        }
        if reader.status == .failed { throw reader.error ?? ExtractError.unreadable(asset.url) }
        return samples
    }

    private func writeWAV(_ samples: ArraySlice<Int16>, to dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(Self.sampleRate), channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.int16ChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try file.write(from: buffer)
        return url
    }
}
