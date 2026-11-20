import SwiftUI
import Combine

/// Holds the state for the project that's currently open, and the list of all projects.
@MainActor
final class RecordingModel: ObservableObject {

    enum Phase {
        case idle                // showing the project list
        case analyzing(Double)   // 0...1
        case ready
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var projects: [ProjectInfo] = []
    @Published var current: ProjectInfo?

    @Published var fileURL: URL?
    @Published var fileName = ""
    @Published var fileSizeMB = 0.0
    @Published var peaks: [Float] = []
    @Published var secondsPerBucket = 0.1
    @Published var loudestPeak: Float = 1
    @Published var activity: ActivityProfile?
    @Published var duration = 0.0
    @Published var sampleRate = 0.0
    @Published var channelCount = 0

    init() {
        ProjectStore.migrateLegacyIfNeeded()
        refreshProjects()
    }

    func refreshProjects() {
        projects = ProjectStore.list()
    }

    // MARK: - Importing a new recording

    /// Called with the URL the Files picker hands back. Creates a new project.
    func importRecording(from pickedURL: URL) {
        fileURL = nil
        current = nil
        phase = .analyzing(0)

        let id = UUID()
        let folder = ProjectStore.folder(id)

        Task {
            do {
                // 1. Copy into the app's own storage (can be slow for big files).
                let localURL = try await Task.detached(priority: .userInitiated) {
                    try FileImport.copy(pickedURL, into: folder)
                }.value

                // 2. Scan it in chunks.
                let result = try await scan(localURL)

                // 3. Save the project and the scan so reopening is instant.
                let info = ProjectInfo(
                    id: id,
                    name: localURL.deletingPathExtension().lastPathComponent,
                    fileName: localURL.lastPathComponent,
                    duration: result.duration,
                    createdAt: Date(),
                    modifiedAt: Date(),
                    cutCount: 0
                )
                ProjectStore.saveInfo(info)
                ProjectStore.saveScan(id, result)
                apply(result, local: localURL, info: info)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Opening, closing, deleting

    func open(_ info: ProjectInfo) {
        fileURL = nil
        current = nil
        phase = .analyzing(0)

        Task {
            do {
                let local = ProjectStore.recordingURL(info)
                guard FileManager.default.fileExists(atPath: local.path) else {
                    throw ProjectError.missingRecording
                }

                let id = info.id
                let cached = await Task.detached(priority: .userInitiated) {
                    ProjectStore.loadScan(id)
                }.value

                if let cached, abs(cached.duration - info.duration) < 0.5 {
                    apply(cached, local: local, info: info)
                } else {
                    // No saved scan (or it doesn't match): scan again and save it.
                    let result = try await scan(local)
                    ProjectStore.saveScan(id, result)
                    apply(result, local: local, info: info)
                }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Renames the open project (the recording file itself isn't touched).
    func rename(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var info = current else { return }
        info.name = trimmed
        ProjectStore.saveInfo(info)
        current = info
        refreshProjects()
    }

    /// Back to the project list. Frees the waveform data held in memory.
    func closeProject() {
        fileURL = nil
        current = nil
        peaks = []
        activity = nil
        phase = .idle
        refreshProjects()
    }

    /// Permanently removes a project's recording, cuts and saved scan.
    func delete(_ info: ProjectInfo) {
        ProjectStore.delete(info.id)
        refreshProjects()
    }

    // MARK: - Scanning

    /// Scans the recording in chunks, off the main thread.
    private func scan(_ localURL: URL) async throws -> WaveformResult {
        try await Task.detached(priority: .userInitiated) { [weak self] in
            try WaveformAnalyzer.analyze(url: localURL) { fraction in
                Task { @MainActor in
                    self?.updateProgress(fraction)
                }
            }
        }.value
    }

    private func apply(_ result: WaveformResult, local: URL, info: ProjectInfo) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: local.path)
        let bytes = (attrs?[.size] as? NSNumber)?.doubleValue ?? 0

        fileName = local.lastPathComponent
        fileSizeMB = bytes / 1_048_576
        peaks = result.peaks
        secondsPerBucket = result.secondsPerBucket
        loudestPeak = max(result.peaks.max() ?? 1, 0.0001)
        activity = result.activity
        duration = result.duration
        sampleRate = result.sampleRate
        channelCount = result.channelCount
        current = info
        fileURL = local
        phase = .ready
    }

    private func updateProgress(_ fraction: Double) {
        if case .analyzing = phase {
            phase = .analyzing(fraction)
        }
    }
}

enum FileImport {
    /// Files-picker URLs are temporary, permission-scoped links. Copy the file
    /// into the project's own folder so we can keep using it afterward.
    nonisolated static func copy(_ url: URL, into folder: URL) throws -> URL {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let dest = folder.appendingPathComponent(url.lastPathComponent)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: url, to: dest)
        return dest
    }
}
