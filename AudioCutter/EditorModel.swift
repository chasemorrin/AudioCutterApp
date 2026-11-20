import SwiftUI
import Combine

/// One cut point. The number shown in the UI is its position in the sorted list.
struct CutMarker: Identifiable, Equatable {
    let id: UUID
    var time: Double

    init(id: UUID = UUID(), time: Double) {
        self.id = id
        self.time = time
    }
}

/// A stretch of the recording, in seconds.
struct TimeRange: Hashable {
    let start: Double
    let end: Double
}

/// A fine-grained slice of peaks for the area you're zoomed in on.
struct DetailPeaks {
    let start: Double
    let end: Double
    let secondsPerBucket: Double
    let peaks: [Float]
}

/// Used to re-check whether we need new detail whenever the view changes.
struct DetailKey: Hashable {
    let start: Double
    let duration: Double
    let width: Double
}

/// What you've decided about a section.
struct SectionInfo {
    var customName: String?   // nil means "use the automatic name"
    var keep: Bool
}

/// A copy of everything undo can restore.
struct EditorSnapshot {
    let markers: [CutMarker]
    let sectionInfo: [UUID: SectionInfo]
    let startKey: UUID
}

/// The stretch of audio between two cut points (or the ends of the recording).
struct CutSection: Identifiable {
    let id: UUID              // the cut point it starts at (or a fixed id for the first section)
    let startCutNumber: Int?  // nil for the first section, which starts at 0:00
    let start: Double
    let end: Double
    let keep: Bool
    let customName: String?
    let autoName: String
    var name: String { customName ?? autoName }
}

/// The editing state: cut points, sections, and how much of the recording is on screen.
@MainActor
final class EditorModel: ObservableObject {

    @Published var markers: [CutMarker] = []
    @Published var viewStart: Double = 0
    @Published var viewDuration: Double = 1
    @Published var detail: DetailPeaks?
    @Published var isInteracting = false      // a finger is on the waveform
    @Published private var sectionInfo: [UUID: SectionInfo] = [:]
    @Published private var undoStack: [EditorSnapshot] = []

    /// While true, the view scrolls to keep the playhead on screen during playback.
    /// Dragging the waveform turns it off so you can look around freely;
    /// starting playback, or tapping the locate button, turns it back on.
    private var autoFollow = true

    var canUndo: Bool { !undoStack.isEmpty }

    private(set) var duration: Double = 0
    private var url: URL?
    private var projectID: UUID?
    private var activity: ActivityProfile?
    private var overviewSecondsPerBucket = 0.1
    private var isLoadingDetail = false
    private var panBase: Double?
    private var pinchBase: (duration: Double, center: Double)?
    private let minViewDuration = 2.0
    private var startKey = UUID()
    private let shortestSongSeconds = 20.0
    private var cancellables = Set<AnyCancellable>()

    /// Where the playhead was when the saved session was written (0 if none).
    private(set) var restoredPlayhead: Double = 0

    init() {
        // Save shortly after any change to cuts, names, or keep/discard.
        Publishers.CombineLatest($markers, $sectionInfo)
            .dropFirst()
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &cancellables)
    }

    // MARK: - Auto-save

    private var lastPlayhead: Double = 0

    /// Writes the current work to disk. Pass the playhead when leaving the app.
    func save(playhead: Double? = nil) {
        guard let url, let projectID, duration > 0 else { return }
        if let playhead { lastPlayhead = playhead }

        var sections: [SavedSession.Sec] = []
        let keys = [startKey] + markers.map { $0.id }
        for key in keys {
            if let info = sectionInfo[key] {
                sections.append(.init(id: key, customName: info.customName, keep: info.keep))
            }
        }

        ProjectStore.saveEdits(projectID, SavedSession(
            fileName: url.lastPathComponent,
            duration: duration,
            startKey: startKey,
            markers: markers.map { .init(id: $0.id, time: $0.time) },
            sections: sections,
            playhead: lastPlayhead
        ))
    }

    private func restore(_ saved: SavedSession) {
        startKey = saved.startKey
        markers = saved.markers.map { CutMarker(id: $0.id, time: $0.time) }
        markers.sort { $0.time < $1.time }
        var info: [UUID: SectionInfo] = [:]
        for s in saved.sections {
            info[s.id] = SectionInfo(customName: s.customName, keep: s.keep)
        }
        sectionInfo = info
        ensureSectionInfo()
        restoredPlayhead = saved.playhead
        lastPlayhead = saved.playhead
    }

    // MARK: - Loading

    func load(
        url: URL,
        duration: Double,
        overviewSecondsPerBucket: Double,
        activity: ActivityProfile?,
        saved: SavedSession? = nil,
        projectID: UUID? = nil
    ) {
        self.url = url
        self.projectID = projectID
        self.duration = duration
        self.overviewSecondsPerBucket = overviewSecondsPerBucket
        self.activity = activity
        markers = []
        sectionInfo = [:]
        detail = nil
        panBase = nil
        pinchBase = nil
        isInteracting = false
        viewStart = 0
        viewDuration = max(duration, 0.1)
        restoredPlayhead = 0
        lastPlayhead = 0

        // Same recording as the saved session? Put everything back.
        if let saved,
           saved.fileName == url.lastPathComponent,
           abs(saved.duration - duration) < 0.5 {
            restore(saved)
        } else {
            startKey = UUID()
            autoDetect(.normal)
        }
        undoStack = []
        autoFollow = true
    }

    // MARK: - Undo

    private func pushUndo() {
        undoStack.append(EditorSnapshot(markers: markers, sectionInfo: sectionInfo, startKey: startKey))
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    /// Reverts the last change to cuts, keep/discard, or section names.
    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        markers = snapshot.markers
        sectionInfo = snapshot.sectionInfo
        startKey = snapshot.startKey
    }

    // MARK: - Cut points

    func addMarker(at time: Double) {
        let t = snapped(time)
        if markers.contains(where: { abs($0.time - t) < 0.05 }) { return }
        pushUndo()
        markers.append(CutMarker(time: t))
        markers.sort { $0.time < $1.time }
        ensureSectionInfo()
    }

    func removeMarker(id: UUID) {
        pushUndo()
        markers.removeAll { $0.id == id }
        sectionInfo[id] = nil
    }

    /// Moves a cut point only. Never touches the playhead or the zoom.
    func nudgeMarker(id: UUID, by delta: Double) {
        guard let i = markers.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        markers[i].time = snapped(markers[i].time + delta)
        markers.sort { $0.time < $1.time }
    }

    /// Replaces all cuts with ones placed at the end of each burst of applause.
    func autoDetect(_ sensitivity: DetectSensitivity) {
        guard let activity else { return }
        pushUndo()
        let times = ApplauseDetector.detect(
            profile: activity,
            totalDuration: duration,
            sensitivity: sensitivity
        )
        markers = times.map { CutMarker(time: snapped($0)) }
        markers.sort { $0.time < $1.time }
        sectionInfo = [:]
        ensureSectionInfo()
    }

    private func snapped(_ time: Double) -> Double {
        let rounded = (time * 20).rounded() / 20          // nearest 0.05 s
        return min(max(rounded, 0.05), max(0.05, duration - 0.05))
    }

    // MARK: - Sections

    private func sectionBounds() -> [Double] {
        var bounds: [Double] = [0]
        bounds.append(contentsOf: markers.map { $0.time })
        bounds.append(duration)
        return bounds
    }

    private func sectionKey(_ index: Int) -> UUID {
        index == 0 ? startKey : markers[index - 1].id
    }

    /// Gives every section a keep/discard choice the first time it appears.
    /// Sections under 20 seconds start out discarded (talking, gaps, etc.).
    private func ensureSectionInfo() {
        let bounds = sectionBounds()
        var info = sectionInfo
        for i in 0..<(bounds.count - 1) {
            let key = sectionKey(i)
            if info[key] == nil {
                info[key] = SectionInfo(
                    customName: nil,
                    keep: bounds[i + 1] - bounds[i] >= shortestSongSeconds
                )
            }
        }
        sectionInfo = info
    }

    /// Sections in order. Names stay attached to the cut point a section starts at,
    /// so nudging or adding other cuts never scrambles them.
    var sections: [CutSection] {
        let bounds = sectionBounds()
        var songNumber = 0
        var result: [CutSection] = []

        for i in 0..<(bounds.count - 1) {
            let key = sectionKey(i)
            let start = bounds[i]
            let end = bounds[i + 1]
            let info = sectionInfo[key] ?? SectionInfo(
                customName: nil,
                keep: end - start >= shortestSongSeconds
            )
            if info.keep { songNumber += 1 }

            result.append(CutSection(
                id: key,
                startCutNumber: i == 0 ? nil : i,
                start: start,
                end: end,
                keep: info.keep,
                customName: info.customName,
                autoName: info.keep ? "Song \(songNumber)" : "Clip"
            ))
        }
        return result
    }

    /// The stretches to dim on the waveform.
    var discardedRanges: [TimeRange] {
        sections.filter { !$0.keep }.map { TimeRange(start: $0.start, end: $0.end) }
    }

    func toggleKeep(id: UUID) {
        guard let section = sections.first(where: { $0.id == id }) else { return }
        pushUndo()
        sectionInfo[id] = SectionInfo(customName: section.customName, keep: !section.keep)
    }

    func setName(_ rawName: String, for id: UUID) {
        guard let section = sections.first(where: { $0.id == id }) else { return }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let custom: String? = (trimmed.isEmpty || trimmed == section.autoName) ? nil : trimmed
        if custom == section.customName { return }
        pushUndo()
        sectionInfo[id] = SectionInfo(customName: custom, keep: section.keep)
    }

    // MARK: - Zoom and pan

    private func clampStart(_ start: Double, span: Double) -> Double {
        min(max(start, 0), max(0, duration - span))
    }

    /// Zoom to a new window length while keeping `anchor` at the same spot on screen.
    func setZoom(duration newDuration: Double, anchor: Double) {
        let lo = min(minViewDuration, duration)
        let clamped = min(max(newDuration, lo), duration)
        let ratio = viewDuration > 0 ? (anchor - viewStart) / viewDuration : 0.5
        viewDuration = clamped
        viewStart = clampStart(anchor - ratio * clamped, span: clamped)
    }

    /// The +/- buttons. Anchored on the playhead if it's visible, else the middle.
    func zoomStep(zoomIn: Bool, playhead: Double) {
        let visible = playhead >= viewStart && playhead <= viewStart + viewDuration
        let anchor = visible ? playhead : viewStart + viewDuration / 2
        setZoom(duration: zoomIn ? viewDuration / 2 : viewDuration * 2, anchor: anchor)
    }

    /// Zoom and scroll so a whole section is centered with a little room on each side.
    func frame(start: Double, end: Double) {
        let length = max(end - start, 0.1)
        let padding = min(max(length * 0.15, 1), 8)
        let lo = min(minViewDuration, duration)
        let newDuration = min(max(length + padding * 2, lo), duration)
        viewDuration = newDuration
        viewStart = clampStart(start - padding, span: newDuration)
        autoFollow = true
    }

    /// Pinch gesture. `scale` is relative to when the pinch began.
    func pinch(scale: Double, final: Bool) {
        if final {
            pinchBase = nil
            isInteracting = false
            return
        }
        isInteracting = true
        if pinchBase == nil {
            pinchBase = (viewDuration, viewStart + viewDuration / 2)
        }
        guard let base = pinchBase, scale > 0.01 else { return }
        let lo = min(minViewDuration, duration)
        let newDuration = min(max(base.duration / scale, lo), duration)
        viewDuration = newDuration
        viewStart = clampStart(base.center - newDuration / 2, span: newDuration)
    }

    /// Drag-to-pan while zoomed in. `fraction` is finger travel as a share of the width.
    func pan(fraction: Double, final: Bool) {
        if final {
            panBase = nil
            isInteracting = false
            return
        }
        isInteracting = true
        autoFollow = false
        if panBase == nil { panBase = viewStart }
        let base = panBase ?? viewStart
        viewStart = clampStart(base - fraction * viewDuration, span: viewDuration)
    }

    /// During playback, keep the playhead on screen without changing the zoom.
    func followPlayhead(_ time: Double) {
        guard autoFollow, !isInteracting, viewDuration < duration else { return }
        if time < viewStart || time > viewStart + viewDuration {
            viewStart = clampStart(time - viewDuration / 2, span: viewDuration)
        }
    }

    /// Start following the playhead again (called when playback starts).
    func resumeFollowing() { autoFollow = true }

    /// Scroll so the playhead is centered, and follow it from here on.
    func centerOn(_ time: Double) {
        autoFollow = true
        viewStart = clampStart(time - viewDuration / 2, span: viewDuration)
    }

    // MARK: - Fine detail for deep zoom

    private func needsDetail(width: Double) -> Bool {
        guard url != nil, width > 1 else { return false }
        let secondsPerPixel = viewDuration / width
        guard secondsPerPixel < overviewSecondsPerBucket * 0.95 else { return false }
        guard let d = detail else { return true }
        let covers = d.start <= viewStart + 0.001 && d.end >= viewStart + viewDuration - 0.001
        return !(covers && d.secondsPerBucket <= secondsPerPixel * 1.05)
    }

    /// Reads a window around the current view from disk when we're zoomed in
    /// further than the overview can show. Reads about three screens' worth so
    /// small pans don't need a new read.
    func updateDetail(width: Double) async {
        guard let url, !isLoadingDetail, needsDetail(width: width) else { return }

        isLoadingDetail = true
        let secondsPerPixel = viewDuration / width
        let margin = viewDuration
        let windowStart = max(0, viewStart - margin)
        let windowEnd = min(duration, viewStart + viewDuration + margin)
        let bucketCount = min(max(Int(ceil((windowEnd - windowStart) / secondsPerPixel)), 1), 8000)
        let bucketSeconds = (windowEnd - windowStart) / Double(bucketCount)

        let peaks = try? await Task.detached(priority: .userInitiated) {
            try WaveformAnalyzer.detailPeaks(
                url: url,
                startTime: windowStart,
                endTime: windowEnd,
                bucketCount: bucketCount
            )
        }.value
        isLoadingDetail = false

        guard let peaks, !peaks.isEmpty else { return }
        detail = DetailPeaks(
            start: windowStart,
            end: windowEnd,
            secondsPerBucket: bucketSeconds,
            peaks: peaks
        )

        // The view may have moved while we were reading.
        if needsDetail(width: width) {
            await updateDetail(width: width)
        }
    }
}
