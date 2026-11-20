import Foundation
import AVFoundation

// MARK: - What gets saved for each project

/// Your decisions for one recording: cuts, section names, keep/discard, playhead.
struct SavedSession: Codable {
    struct Mark: Codable {
        var id: UUID
        var time: Double
    }
    struct Sec: Codable {
        var id: UUID
        var customName: String?
        var keep: Bool
    }

    var fileName: String
    var duration: Double
    var startKey: UUID
    var markers: [Mark]
    var sections: [Sec]
    var playhead: Double
}

/// The summary shown in the project list.
struct ProjectInfo: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var fileName: String
    var duration: Double
    var createdAt: Date
    var modifiedAt: Date
    var cutCount: Int
    var sizeBytes: Int64 = 0      // refreshed whenever the list is built
}

enum ProjectError: LocalizedError {
    case missingRecording

    var errorDescription: String? {
        switch self {
        case .missingRecording: return "This project's recording file is missing."
        }
    }
}

// MARK: - Saved scan results (so reopening is instant)

enum ScanCache {

    private nonisolated static let magic = Data("ACS1".utf8)

    nonisolated static func encode(_ r: WaveformResult) -> Data {
        var d = magic

        func f64(_ v: Double) {
            var x = v.bitPattern.littleEndian
            withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
        }
        func u32(_ v: Int) {
            var x = UInt32(v).littleEndian
            withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
        }

        f64(r.secondsPerBucket)
        f64(r.duration)
        f64(r.sampleRate)
        f64(r.activity.windowSeconds)
        u32(r.channelCount)
        u32(r.peaks.count)
        u32(r.activity.rms.count)

        r.peaks.withUnsafeBytes { d.append(contentsOf: $0) }
        r.activity.rms.withUnsafeBytes { d.append(contentsOf: $0) }
        r.activity.zcr.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    nonisolated static func decode(_ data: Data) -> WaveformResult? {
        let headerSize = 4 + 4 * 8 + 3 * 4
        guard data.count >= headerSize, data.prefix(4) == magic else { return nil }

        return data.withUnsafeBytes { raw -> WaveformResult? in
            func f64(_ offset: Int) -> Double {
                Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
            }
            func u32(_ offset: Int) -> Int {
                Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }

            let secondsPerBucket = f64(4)
            let duration = f64(12)
            let sampleRate = f64(20)
            let windowSeconds = f64(28)
            let channels = u32(36)
            let peakCount = u32(40)
            let activityCount = u32(44)

            let expected = headerSize + 4 * (peakCount + 2 * activityCount)
            guard data.count == expected else { return nil }

            func floats(at offset: Int, count: Int) -> [Float] {
                var array = [Float](repeating: 0, count: count)
                array.withUnsafeMutableBytes { destination in
                    destination.copyMemory(
                        from: UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + count * 4)])
                    )
                }
                return array
            }

            let peaks = floats(at: headerSize, count: peakCount)
            let rms = floats(at: headerSize + 4 * peakCount, count: activityCount)
            let zcr = floats(at: headerSize + 4 * (peakCount + activityCount), count: activityCount)

            return WaveformResult(
                peaks: peaks,
                secondsPerBucket: secondsPerBucket,
                activity: ActivityProfile(rms: rms, zcr: zcr, windowSeconds: windowSeconds),
                duration: duration,
                sampleRate: sampleRate,
                channelCount: channels
            )
        }
    }
}

// MARK: - Project storage on disk
//
//  Documents/Projects/<id>/
//      info.json      name, length, dates, cut count
//      edits.json     cuts, section names, keep/discard, playhead
//      scan.bin       saved scan results
//      <recording>    the audio file

enum ProjectStore {

    nonisolated static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Projects", isDirectory: true)
    }

    nonisolated static func folder(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private nonisolated static func infoURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("info.json") }
    private nonisolated static func editsURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("edits.json") }
    private nonisolated static func scanURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("scan.bin") }

    nonisolated static func recordingURL(_ info: ProjectInfo) -> URL {
        folder(info.id).appendingPathComponent(info.fileName)
    }

    private nonisolated static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private nonisolated static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: Info

    nonisolated static func saveInfo(_ info: ProjectInfo) {
        try? FileManager.default.createDirectory(at: folder(info.id), withIntermediateDirectories: true)
        guard let data = try? encoder().encode(info) else { return }
        try? data.write(to: infoURL(info.id), options: .atomic)
    }

    nonisolated static func loadInfo(_ id: UUID) -> ProjectInfo? {
        guard let data = try? Data(contentsOf: infoURL(id)) else { return nil }
        return try? decoder().decode(ProjectInfo.self, from: data)
    }

    // MARK: Edits

    nonisolated static func loadEdits(_ id: UUID) -> SavedSession? {
        guard let data = try? Data(contentsOf: editsURL(id)) else { return nil }
        return try? JSONDecoder().decode(SavedSession.self, from: data)
    }

    /// Written atomically, so a crash mid-save can't leave a half-written file.
    /// Does nothing if the project has been deleted in the meantime.
    nonisolated static func saveEdits(_ id: UUID, _ session: SavedSession) {
        guard var info = loadInfo(id) else { return }
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? data.write(to: editsURL(id), options: .atomic)

        info.modifiedAt = Date()
        info.cutCount = session.markers.count
        saveInfo(info)
    }

    // MARK: Scan results

    nonisolated static func saveScan(_ id: UUID, _ result: WaveformResult) {
        try? ScanCache.encode(result).write(to: scanURL(id), options: .atomic)
    }

    nonisolated static func loadScan(_ id: UUID) -> WaveformResult? {
        guard let data = try? Data(contentsOf: scanURL(id)) else { return nil }
        return ScanCache.decode(data)
    }

    // MARK: List and delete

    nonisolated static func list() -> [ProjectInfo] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [ProjectInfo] = []
        for url in folders {
            guard let id = UUID(uuidString: url.lastPathComponent) else { continue }
            if var info = loadInfo(id) {
                info.sizeBytes = folderSize(url)
                result.append(info)
            } else {
                // A leftover from an import that never finished: clean it up.
                try? fm.removeItem(at: url)
            }
        }
        return result.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Removes the recording, cuts, and saved scan for a project.
    nonisolated static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(id))
    }

    private nonisolated static func folderSize(_ url: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }

    // MARK: Moving over from the single-project version

    /// Earlier versions kept one recording in Documents/Recordings plus session.json.
    /// Turn whatever is there into projects so nothing is lost.
    nonisolated static func migrateLegacyIfNeeded() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let legacyFolder = docs.appendingPathComponent("Recordings", isDirectory: true)
        let legacySession = docs.appendingPathComponent("session.json")

        guard let files = try? fm.contentsOfDirectory(
            at: legacyFolder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            try? fm.removeItem(at: legacySession)
            return
        }

        let oldSession = (try? Data(contentsOf: legacySession))
            .flatMap { try? JSONDecoder().decode(SavedSession.self, from: $0) }

        for file in files {
            guard let audio = try? AVAudioFile(forReading: file) else { continue }
            let duration = Double(audio.length) / audio.processingFormat.sampleRate

            let id = UUID()
            try? fm.createDirectory(at: folder(id), withIntermediateDirectories: true)
            let destination = folder(id).appendingPathComponent(file.lastPathComponent)
            guard (try? fm.moveItem(at: file, to: destination)) != nil else {
                try? fm.removeItem(at: folder(id))
                continue
            }

            var edits: SavedSession?
            if let s = oldSession, s.fileName == file.lastPathComponent, abs(s.duration - duration) < 0.5 {
                edits = s
                if let data = try? JSONEncoder().encode(s) {
                    try? data.write(to: editsURL(id), options: .atomic)
                }
            }

            saveInfo(ProjectInfo(
                id: id,
                name: file.deletingPathExtension().lastPathComponent,
                fileName: file.lastPathComponent,
                duration: duration,
                createdAt: Date(),
                modifiedAt: Date(),
                cutCount: edits?.markers.count ?? 0
            ))
        }

        try? fm.removeItem(at: legacyFolder)
        try? fm.removeItem(at: legacySession)
    }
}
