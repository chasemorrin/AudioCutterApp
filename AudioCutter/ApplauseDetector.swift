import Foundation

/// How aggressively to look for applause.
enum DetectSensitivity: String, CaseIterable, Identifiable {
    case strict
    case normal
    case sensitive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .strict: return "Strict (fewer cuts)"
        case .normal: return "Normal"
        case .sensitive: return "Sensitive (more cuts)"
        }
    }

    /// How far above the recording's average "noisiness" a stretch must be.
    var noiseMultiplier: Double {
        switch self {
        case .strict: return 1.8
        case .normal: return 1.3
        case .sensitive: return 0.9
        }
    }

    /// How long the applause has to last, in seconds.
    var minimumSeconds: Double {
        switch self {
        case .strict: return 4
        case .normal: return 3
        case .sensitive: return 2
        }
    }
}

/// How loud and how "noisy" each 0.05 second slice of the recording is.
/// Measured during the first scan so we never need the audio again to detect cuts.
struct ActivityProfile: Sendable {
    let rms: [Float]          // loudness of each slice
    let zcr: [Float]          // zero-crossing rate: high for noise like clapping
    let windowSeconds: Double
}

enum ApplauseDetector {

    /// Applause is loud, sustained, broadband noise, unlike the more tonal sound
    /// of a song. Each slice that is both audible and noisier than usual counts as
    /// "applause-like"; a long enough run of them is one burst of applause.
    /// Returns one cut time per burst, placed where the applause ends (where the
    /// next piece of music starts).
    static func detect(
        profile: ActivityProfile,
        totalDuration: Double,
        sensitivity: DetectSensitivity
    ) -> [Double] {

        let count = profile.zcr.count
        guard count > 0, profile.windowSeconds > 0 else { return [] }

        let silenceFloor = Float(pow(10.0, -38.0 / 20.0))

        var sum = 0.0
        for value in profile.zcr { sum += Double(value) }
        let mean = sum / Double(count)

        var squares = 0.0
        for value in profile.zcr {
            let d = Double(value) - mean
            squares += d * d
        }
        let deviation = (squares / Double(count)).squareRoot()
        let threshold = Float(mean + sensitivity.noiseMultiplier * deviation)

        let minimumWindows = Int((sensitivity.minimumSeconds / profile.windowSeconds).rounded(.up))

        var burstEnds: [Double] = []
        var runStart: Int?

        func closeRun(at window: Int) {
            guard let start = runStart else { return }
            if window - start >= minimumWindows {
                let startTime = Double(start) * profile.windowSeconds
                let endTime = Double(window) * profile.windowSeconds
                // ignore bursts touching the very start or end of the recording
                if startTime > 0.5 && endTime < totalDuration - 0.5 {
                    burstEnds.append(endTime)
                }
            }
            runStart = nil
        }

        for w in 0..<count {
            let applauseLike = profile.zcr[w] > threshold && profile.rms[w] > silenceFloor
            if applauseLike {
                if runStart == nil { runStart = w }
            } else {
                closeRun(at: w)
            }
        }
        closeRun(at: count)

        burstEnds.sort()
        var merged: [Double] = []
        for time in burstEnds {
            if let last = merged.last, time - last <= 0.3 { continue }
            merged.append(time)
        }
        return merged
    }
}
