import AVFoundation
import SwiftUI
import Combine

/// The audio format of the exported files.
enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case alac, aac, wav

    var id: String { rawValue }

    var label: String {
        switch self {
        case .alac: return "Apple Lossless"
        case .aac: return "AAC"
        case .wav: return "WAV"
        }
    }

    var note: String {
        switch self {
        case .alac: return "M4A, full quality. Best choice for Apple Music."
        case .aac: return "M4A, much smaller files."
        case .wav: return "Uncompressed. Apple Music often ignores its tags."
        }
    }

    var fileExtension: String {
        self == .wav ? "wav" : "m4a"
    }
}

/// Choices made in the export panel.
struct ExportOptions: Sendable {
    var format: ExportFormat = .alac
    var asZip = false
    var artist = ""
    var albumArtist = ""
    var album = ""

    var hasMetadata: Bool {
        !artist.isEmpty || !albumArtist.isEmpty || !album.isEmpty
    }
}

/// One song to cut out of the recording.
struct ExportJob: Sendable {
    let fileName: String      // already numbered, e.g. "01 - Song 1.wav"
    let title: String         // the song name, for the Title tag
    let trackNumber: Int
    let trackCount: Int
    let start: Double
    let end: Double
}

enum ExportEngine {

    /// Cuts each job straight from the source file to its own WAV file, reading
    /// and writing ~64k frames at a time. Memory stays flat no matter how long
    /// the songs are. Returns the finished files (or the single zip).
    nonisolated static func export(
        source: URL,
        jobs: [ExportJob],
        folder: URL,
        options: ExportOptions,
        progress: @escaping @Sendable (Double, String) -> Void
    ) throws -> [URL] {

        let fm = FileManager.default
        if fm.fileExists(atPath: folder.path) {
            try fm.removeItem(at: folder)
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let sampleRate = format.sampleRate
        let totalFrames = Int(input.length)

        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw AnalyzerError.bufferUnavailable
        }

        let settings = outputSettings(
            format: options.format,
            sampleRate: sampleRate,
            channels: Int(format.channelCount)
        )

        // total work, for the progress bar
        var totalToWrite = 0
        for job in jobs {
            let s = max(0, Int(job.start * sampleRate))
            let e = min(totalFrames, Int(job.end * sampleRate))
            totalToWrite += max(0, e - s)
        }
        totalToWrite = max(totalToWrite, 1)
        var written = 0

        var outputs: [URL] = []

        for job in jobs {
            let startFrame = max(0, Int(job.start * sampleRate))
            let endFrame = min(totalFrames, Int(job.end * sampleRate))
            if endFrame <= startFrame { continue }

            let finalURL = folder.appendingPathComponent(job.fileName)
            // M4A tags are added in a second step, so the first pass goes to a scratch file.
            let tagsInSecondStep = options.hasMetadata && options.format != .wav
            let outURL = tagsInSecondStep
                ? folder.appendingPathComponent("tmp-" + job.fileName)
                : finalURL
            // Scope the output file so it is closed (and the WAV header finalized)
            // before we add tags to it.
            do {
                let output = try AVAudioFile(
                    forWriting: outURL,
                    settings: settings,
                    commonFormat: format.commonFormat,
                    interleaved: format.isInterleaved
                )
                input.framePosition = AVAudioFramePosition(startFrame)
                var position = startFrame

                while position < endFrame {
                    let toRead = AVAudioFrameCount(min(Int(chunk), endFrame - position))
                    buffer.frameLength = 0
                    try input.read(into: buffer, frameCount: toRead)
                    if buffer.frameLength == 0 { break }
                    try output.write(from: buffer)
                    position += Int(buffer.frameLength)
                    written += Int(buffer.frameLength)
                    progress(min(1, Double(written) / Double(totalToWrite)), job.fileName)
                }
            }

            if options.hasMetadata {
                let albumArtist = options.albumArtist.isEmpty ? options.artist : options.albumArtist
                if options.format == .wav {
                    let tag = id3Tag(
                        title: job.title,
                        artist: options.artist,
                        albumArtist: albumArtist,
                        album: options.album,
                        track: job.trackNumber,
                        trackCount: job.trackCount
                    )
                    try appendID3Chunk(tag, to: finalURL)
                } else {
                    progress(min(1, Double(written) / Double(totalToWrite)), "Tagging \(job.fileName)")
                    try tagM4A(
                        raw: outURL,
                        final: finalURL,
                        items: m4aMetadata(
                            title: job.title,
                            artist: options.artist,
                            albumArtist: albumArtist,
                            album: options.album,
                            track: job.trackNumber,
                            trackCount: job.trackCount
                        )
                    )
                    try? fm.removeItem(at: outURL)
                }
            }
            outputs.append(finalURL)
        }

        if options.asZip {
            progress(1, "Zipping…")
            let zipName = safeName(options.album.isEmpty ? "Audio Cutter" : options.album) + ".zip"
            let zipURL = folder.appendingPathComponent(zipName)
            try makeZip(files: outputs, to: zipURL)
            for url in outputs { try? fm.removeItem(at: url) }   // keep only the zip
            return [zipURL]
        }

        progress(1, "")
        return outputs
    }

    /// Encoder settings for each format.
    private nonisolated static func outputSettings(
        format: ExportFormat,
        sampleRate: Double,
        channels: Int
    ) -> [String: Any] {
        switch format {
        case .wav:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
        case .alac:
            return [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitDepthHintKey: 16
            ]
        case .aac:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 256_000 * min(channels, 2) / 2
            ]
        }
    }

    // MARK: - Metadata (M4A)

    private nonisolated static func m4aMetadata(
        title: String,
        artist: String,
        albumArtist: String,
        album: String,
        track: Int,
        trackCount: Int
    ) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []

        func text(_ id: AVMetadataIdentifier, _ value: String) {
            guard !value.isEmpty else { return }
            let item = AVMutableMetadataItem()
            item.identifier = id
            item.value = value as NSString
            item.dataType = "com.apple.metadata.datatype.UTF-8"
            item.extendedLanguageTag = "und"
            items.append(item)
        }

        text(.iTunesMetadataSongName, title)
        text(.iTunesMetadataArtist, artist)
        text(.iTunesMetadataAlbum, album)
        text(.iTunesMetadataAlbumArtist, albumArtist)

        // Track number is stored as 8 raw bytes: 0, 0, track (2), total (2), 0, 0.
        let bytes: [UInt8] = [
            0, 0,
            UInt8((track >> 8) & 0xFF), UInt8(track & 0xFF),
            UInt8((trackCount >> 8) & 0xFF), UInt8(trackCount & 0xFF),
            0, 0
        ]
        let trackItem = AVMutableMetadataItem()
        trackItem.identifier = .iTunesMetadataTrackNumber
        trackItem.value = Data(bytes) as NSData
        trackItem.dataType = "com.apple.metadata.datatype.raw-data"
        items.append(trackItem)

        return items
    }

    /// Copies the audio into a new M4A without re-encoding and attaches the tags.
    private nonisolated static func tagM4A(raw: URL, final: URL, items: [AVMetadataItem]) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }

        let asset = AVURLAsset(url: raw)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.fileWriteUnknown)
        }
        session.outputURL = final
        session.outputFileType = .m4a
        session.metadata = items

        let done = DispatchSemaphore(value: 0)
        session.exportAsynchronously { done.signal() }
        done.wait()

        if session.status != .completed {
            throw session.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    /// Makes a name safe to use as a file name.
    nonisolated static func safeName(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = raw.components(separatedBy: illegal).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Song" : cleaned
    }

    // MARK: - Metadata (ID3 tag inside the WAV file)

    private nonisolated static func le32(_ v: UInt32) -> Data {
        withUnsafeBytes(of: v.littleEndian) { Data($0) }
    }
    private nonisolated static func le16(_ v: UInt16) -> Data {
        withUnsafeBytes(of: v.littleEndian) { Data($0) }
    }
    private nonisolated static func be32(_ v: UInt32) -> Data {
        withUnsafeBytes(of: v.bigEndian) { Data($0) }
    }

    /// An ID3v2.3 tag with title, artist, album, album artist and track number.
    /// Apple Music reads these from WAV files.
    private nonisolated static func id3Tag(
        title: String,
        artist: String,
        albumArtist: String,
        album: String,
        track: Int,
        trackCount: Int
    ) -> Data {
        var frames = Data()

        func add(_ id: String, _ text: String) {
            guard !text.isEmpty, let encoded = text.data(using: .utf16LittleEndian) else { return }
            var body = Data([0x01, 0xFF, 0xFE])        // UTF-16 with byte-order mark
            body.append(encoded)
            frames.append(Data(id.utf8))
            frames.append(be32(UInt32(body.count)))
            frames.append(Data([0x00, 0x00]))
            frames.append(body)
        }

        add("TIT2", title)
        add("TPE1", artist)
        add("TALB", album)
        add("TPE2", albumArtist)
        add("TRCK", "\(track)/\(trackCount)")

        let size = UInt32(frames.count)
        var tag = Data("ID3".utf8)
        tag.append(contentsOf: [0x03, 0x00, 0x00])
        tag.append(contentsOf: [
            UInt8((size >> 21) & 0x7F),
            UInt8((size >> 14) & 0x7F),
            UInt8((size >> 7) & 0x7F),
            UInt8(size & 0x7F)
        ])
        tag.append(frames)
        return tag
    }

    /// Adds an "id3 " chunk to the end of a finished WAV file and fixes the
    /// overall RIFF size in the header.
    private nonisolated static func appendID3Chunk(_ tag: Data, to url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        var end = try handle.seekToEnd()
        if end % 2 == 1 {                       // chunks must start on an even byte
            try handle.write(contentsOf: Data([0]))
            end += 1
        }

        var chunk = Data("id3 ".utf8)
        chunk.append(le32(UInt32(tag.count)))
        chunk.append(tag)
        if tag.count % 2 == 1 { chunk.append(0) }
        try handle.write(contentsOf: chunk)

        let newEnd = end + UInt64(chunk.count)
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: le32(UInt32(newEnd - 8)))
    }

    // MARK: - Zip (uncompressed, streamed from disk)

    private nonisolated static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    private nonisolated static func crc32(of url: URL) throws -> UInt32 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var crc: UInt32 = 0xFFFFFFFF
        while true {
            let data = try handle.read(upToCount: 1 << 20) ?? Data()
            if data.isEmpty { break }
            for byte in data {
                crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    /// Writes a standard zip using "stored" (no compression). WAV audio barely
    /// compresses anyway, and this way files are copied through in small pieces.
    private nonisolated static func makeZip(files: [URL], to zipURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: zipURL.path) { try fm.removeItem(at: zipURL) }
        fm.createFile(atPath: zipURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: zipURL)
        defer { try? out.close() }

        let now = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        let dosTime = UInt16(((now.hour ?? 0) << 11) | ((now.minute ?? 0) << 5) | ((now.second ?? 0) / 2))
        let dosDate = UInt16((((now.year ?? 1980) - 1980) << 9) | ((now.month ?? 1) << 5) | (now.day ?? 1))
        let utf8Flag: UInt16 = 0x0800

        struct Entry {
            let name: Data
            let crc: UInt32
            let size: UInt32
            let offset: UInt32
        }
        var entries: [Entry] = []

        for file in files {
            let attrs = try fm.attributesOfItem(atPath: file.path)
            let rawSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let position = try out.offset()
            guard rawSize < 0xFFFF_FFFF, position < 0xFFFF_FFFF else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            let size = UInt32(rawSize)
            let crc = try crc32(of: file)
            let name = Data(file.lastPathComponent.utf8)

            var header = Data()
            header.append(le32(0x04034b50))
            header.append(le16(20))
            header.append(le16(utf8Flag))
            header.append(le16(0))                  // stored
            header.append(le16(dosTime))
            header.append(le16(dosDate))
            header.append(le32(crc))
            header.append(le32(size))
            header.append(le32(size))
            header.append(le16(UInt16(name.count)))
            header.append(le16(0))
            header.append(name)
            try out.write(contentsOf: header)

            let reader = try FileHandle(forReadingFrom: file)
            while true {
                let data = try reader.read(upToCount: 1 << 20) ?? Data()
                if data.isEmpty { break }
                try out.write(contentsOf: data)
            }
            try? reader.close()

            entries.append(Entry(name: name, crc: crc, size: size, offset: UInt32(position)))
        }

        let directoryStart = try out.offset()
        var directory = Data()
        for e in entries {
            directory.append(le32(0x02014b50))
            directory.append(le16(20))
            directory.append(le16(20))
            directory.append(le16(utf8Flag))
            directory.append(le16(0))
            directory.append(le16(dosTime))
            directory.append(le16(dosDate))
            directory.append(le32(e.crc))
            directory.append(le32(e.size))
            directory.append(le32(e.size))
            directory.append(le16(UInt16(e.name.count)))
            directory.append(le16(0))               // extra
            directory.append(le16(0))               // comment
            directory.append(le16(0))               // disk
            directory.append(le16(0))               // internal attributes
            directory.append(le32(0))               // external attributes
            directory.append(le32(e.offset))
            directory.append(e.name)
        }
        try out.write(contentsOf: directory)

        var end = Data()
        end.append(le32(0x06054b50))
        end.append(le16(0))
        end.append(le16(0))
        end.append(le16(UInt16(entries.count)))
        end.append(le16(UInt16(entries.count)))
        end.append(le32(UInt32(directory.count)))
        end.append(le32(UInt32(directoryStart)))
        end.append(le16(0))
        try out.write(contentsOf: end)
    }
}

/// Drives the Export button.
@MainActor
final class ExportModel: ObservableObject {

    enum Phase {
        case idle
        case exporting(Double, String)
        case done([URL])
        case failed(String)
    }

    @Published var phase: Phase = .idle

    var isExporting: Bool {
        if case .exporting = phase { return true }
        return false
    }

    func reset() { phase = .idle }

    /// Exports the kept sections as "NN - Name", numbered in order.
    func export(source: URL, sections: [CutSection], options: ExportOptions) {
        let kept = sections.filter { $0.keep }
        guard !kept.isEmpty else {
            phase = .failed("No sections are marked Keep.")
            return
        }

        var cleaned = options
        cleaned.artist = options.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.albumArtist = options.albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.album = options.album.trimmingCharacters(in: .whitespacesAndNewlines)

        let digits = max(2, String(kept.count).count)
        var jobs: [ExportJob] = []
        for (index, section) in kept.enumerated() {
            let number = String(format: "%0\(digits)d", index + 1)
            jobs.append(ExportJob(
                fileName: "\(number) - \(ExportEngine.safeName(section.name)).\(options.format.fileExtension)",
                title: section.name,
                trackNumber: index + 1,
                trackCount: kept.count,
                start: section.start,
                end: section.end
            ))
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Export", isDirectory: true)
        let finalOptions = cleaned

        phase = .exporting(0, jobs[0].fileName)

        Task {
            do {
                let urls = try await Task.detached(priority: .userInitiated) { [weak self] in
                    try ExportEngine.export(
                        source: source,
                        jobs: jobs,
                        folder: folder,
                        options: finalOptions
                    ) { fraction, name in
                        Task { @MainActor in
                            self?.update(fraction, name)
                        }
                    }
                }.value
                phase = .done(urls)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func update(_ fraction: Double, _ name: String) {
        if case .exporting = phase {
            phase = .exporting(fraction, name)
        }
    }
}

/// The export area shown at the bottom of the Sections tab.
struct ExportPanel: View {
    @ObservedObject var exporter: ExportModel
    let keptCount: Int
    let onStart: (ExportOptions) -> Void

    // Remembered between launches so you don't retype them.
    @AppStorage("exportArtist") private var artist = ""
    @AppStorage("exportAlbumArtist") private var albumArtist = ""
    @AppStorage("exportAlbum") private var album = ""
    @AppStorage("exportAsZip") private var asZip = false
    @AppStorage("exportFormat") private var formatRaw = ExportFormat.alac.rawValue

    private var format: ExportFormat {
        ExportFormat(rawValue: formatRaw) ?? .alac
    }

    private let mint = Color(red: 0.33, green: 0.79, blue: 0.64)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch exporter.phase {
            case .idle:
                idleContent

            case .exporting(let fraction, let name):
                ProgressView(value: fraction)
                Text(name == "Zipping…" ? "Zipping…" : "Cutting \(name)… \(Int(fraction * 100))%")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

            case .done(let urls):
                let isZip = urls.first?.pathExtension.lowercased() == "zip"
                Text(isZip ? "Zip file ready" : "\(urls.count) file\(urls.count == 1 ? "" : "s") ready")
                    .font(.subheadline.weight(.semibold))
                ShareLink(items: urls) {
                    Label("Share / Save to Files", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(mint)
                Text("In the share sheet choose “Save to Files” and pick a folder.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Export again") { exporter.reset() }
                    .buttonStyle(.bordered)

            case .failed(let message):
                Text("Export failed")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Try again") { exporter.reset() }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.top, 8)
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            idleControls
        }
    }

    @ViewBuilder
    private var idleControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Format").font(.subheadline)
                Spacer()
                Picker("Format", selection: $formatRaw) {
                    ForEach(ExportFormat.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            Text(format.note)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Picker("Output", selection: $asZip) {
            Text("Individual files").tag(false)
            Text("One zip file").tag(true)
        }
        .pickerStyle(.segmented)

        DisclosureGroup("Tags for Apple Music (optional)") {
            VStack(spacing: 8) {
                TextField("Artist", text: $artist)
                TextField("Album artist (defaults to Artist)", text: $albumArtist)
                TextField("Album", text: $album)
                Text(format == .wav
                     ? "Apple Music often ignores tags in WAV files. Choose Apple Lossless or AAC for tags that work."
                     : "Every file gets the same artist and album, plus its own title and track number, so they group together as one album when imported.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .textFieldStyle(.roundedBorder)
            .padding(.top, 8)
        }
        .font(.subheadline)

        Button {
            onStart(ExportOptions(
                format: format,
                asZip: asZip,
                artist: artist,
                albumArtist: albumArtist,
                album: album
            ))
        } label: {
            Label(
                "Export \(keptCount) song\(keptCount == 1 ? "" : "s") as \(asZip ? "zip" : format.fileExtension.uppercased())",
                systemImage: "square.and.arrow.down"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(mint)
        .disabled(keptCount == 0)
    }
}
