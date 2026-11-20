import AVFoundation

/// Result of scanning a recording. Only small summary data is kept;
/// the audio itself is never held in memory all at once.
struct WaveformResult: Sendable {
    let peaks: [Float]            // loudest-sample value (0...1) for each bucket
    let secondsPerBucket: Double  // how much time one bucket covers
    let activity: ActivityProfile // loudness / noisiness per 0.05 s, for applause detection
    let duration: Double          // seconds
    let sampleRate: Double
    let channelCount: Int
}

enum AnalyzerError: LocalizedError {
    case emptyFile
    case bufferUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyFile: return "That file doesn't contain any audio."
        case .bufferUnavailable: return "Couldn't allocate an audio buffer."
        }
    }
}

enum WaveformAnalyzer {

    /// Reads the file in small chunks. In a single pass it records:
    ///  - the peak level for each ~0.1 second slice (for drawing the waveform)
    ///  - loudness and noisiness for each 0.05 second slice (for finding applause)
    /// Memory use stays flat (one ~64k-frame buffer) however long the recording is.
    nonisolated static func analyze(
        url: URL,
        secondsPerBucket: Double = 0.1,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> WaveformResult {

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let totalFrames = Int(file.length)
        guard totalFrames > 0 else { throw AnalyzerError.emptyFile }

        let chunkFrames: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw AnalyzerError.bufferUnavailable
        }

        let channelCount = Int(format.channelCount)
        let channelScale = 1 / Float(channelCount)

        // waveform buckets
        let framesPerBucket = max(1, Int((format.sampleRate * secondsPerBucket).rounded()))
        let bucketCount = totalFrames / framesPerBucket + 1
        var peaks = [Float](repeating: 0, count: bucketCount)

        // applause detection windows
        let windowFrames = max(1, Int((format.sampleRate * 0.05).rounded()))
        var rmsValues: [Float] = []
        var zcrValues: [Float] = []
        rmsValues.reserveCapacity(totalFrames / windowFrames + 1)
        zcrValues.reserveCapacity(totalFrames / windowFrames + 1)
        var windowSumSquares: Float = 0
        var windowCrossings = 0
        var windowCount = 0
        var previousMono: Float = 0
        var hasPrevious = false

        var framePosition = 0
        var lastReported = 0.0

        while framePosition < totalFrames {
            try file.read(into: buffer, frameCount: chunkFrames)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let channels = buffer.floatChannelData else { break }

            for i in 0..<n {
                var loudest: Float = 0
                var sum: Float = 0
                for c in 0..<channelCount {
                    let sample = channels[c][i]
                    sum += sample
                    let v = abs(sample)
                    if v > loudest { loudest = v }
                }

                let bucket = (framePosition + i) / framesPerBucket
                if loudest > peaks[bucket] { peaks[bucket] = loudest }

                let mono = sum * channelScale
                windowSumSquares += mono * mono
                if hasPrevious && ((mono >= 0) != (previousMono >= 0)) {
                    windowCrossings += 1
                }
                previousMono = mono
                hasPrevious = true
                windowCount += 1

                if windowCount == windowFrames {
                    rmsValues.append((windowSumSquares / Float(windowCount)).squareRoot())
                    zcrValues.append(Float(windowCrossings) / Float(windowCount))
                    windowSumSquares = 0
                    windowCrossings = 0
                    windowCount = 0
                }
            }

            framePosition += n

            let fraction = Double(framePosition) / Double(totalFrames)
            if fraction - lastReported >= 0.01 {
                lastReported = fraction
                progress(min(1, fraction))
            }
        }

        if windowCount > 0 {
            rmsValues.append((windowSumSquares / Float(windowCount)).squareRoot())
            zcrValues.append(Float(windowCrossings) / Float(windowCount))
        }

        progress(1)
        return WaveformResult(
            peaks: peaks,
            secondsPerBucket: Double(framesPerBucket) / format.sampleRate,
            activity: ActivityProfile(
                rms: rmsValues,
                zcr: zcrValues,
                windowSeconds: Double(windowFrames) / format.sampleRate
            ),
            duration: Double(totalFrames) / format.sampleRate,
            sampleRate: format.sampleRate,
            channelCount: channelCount
        )
    }

    /// Reads just one window of the file and returns a fine-grained set of
    /// peaks for it. Used when you zoom in past what the overview can show.
    nonisolated static func detailPeaks(
        url: URL,
        startTime: Double,
        endTime: Double,
        bucketCount: Int
    ) throws -> [Float] {

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate

        let startFrame = max(0, Int(startTime * sampleRate))
        let endFrame = min(Int(file.length), Int(endTime * sampleRate))
        let windowFrames = endFrame - startFrame
        guard windowFrames > 0, bucketCount > 0 else { return [] }

        file.framePosition = AVAudioFramePosition(startFrame)

        let chunkFrames: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw AnalyzerError.bufferUnavailable
        }

        let channelCount = Int(format.channelCount)
        var peaks = [Float](repeating: 0, count: bucketCount)
        var position = startFrame

        while position < endFrame {
            let toRead = AVAudioFrameCount(min(Int(chunkFrames), endFrame - position))
            try file.read(into: buffer, frameCount: toRead)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let channels = buffer.floatChannelData else { break }

            for i in 0..<n {
                var loudest: Float = 0
                for c in 0..<channelCount {
                    let v = abs(channels[c][i])
                    if v > loudest { loudest = v }
                }
                let bucket = min(bucketCount - 1, (position - startFrame + i) * bucketCount / windowFrames)
                if loudest > peaks[bucket] { peaks[bucket] = loudest }
            }

            position += n
        }

        return peaks
    }
}
