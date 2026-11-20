import SwiftUI

/// The editing screen: a fixed top area (waveform, transport, Add cut) with
/// the cut point / section lists scrolling underneath.
struct EditorView: View {
    @ObservedObject var model: RecordingModel
    @ObservedObject var player: PlayerController
    @ObservedObject var editor: EditorModel
    let chooseAnother: () -> Void

    private enum ListTab {
        case cuts
        case sections
    }

    @StateObject private var exporter = ExportModel()
    @State private var tab: ListTab = .cuts
    @State private var showReplaceConfirm = false
    @State private var pendingSensitivity: DetectSensitivity = .normal

    private let amber = Color(red: 0.89, green: 0.63, blue: 0.24)

    var body: some View {
        GeometryReader { geo in
            let waveformWidth = max(Double(geo.size.width) - 32, 100)
            let sections = editor.sections
            let keptCount = sections.filter { $0.keep }.count

            let isWide = geo.size.width >= 700      // iPad, or iPhone turned sideways

            VStack(spacing: 0) {
                header(wide: isWide)
                Divider()

                if isWide {
                    // Cut points and sections side by side.
                    wideLists(sections: sections, keptCount: keptCount)
                } else {
                    Picker("List", selection: $tab) {
                        Text("Cut points (\(editor.markers.count))").tag(ListTab.cuts)
                        Text("Sections (\(keptCount) of \(sections.count))").tag(ListTab.sections)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                    list(sections: sections, keptCount: keptCount)
                }
            }
            .task(id: DetailKey(start: editor.viewStart, duration: editor.viewDuration, width: waveformWidth)) {
                await editor.updateDetail(width: waveformWidth)
            }
            .onReceive(player.$currentTime) { time in
                if player.isPlaying {
                    editor.followPlayhead(time)
                }
            }
            .onReceive(player.$isPlaying) { playing in
                if playing { editor.resumeFollowing() }
            }
            .confirmationDialog(
                "Replace your current cuts?",
                isPresented: $showReplaceConfirm,
                titleVisibility: .visible
            ) {
                Button("Replace cuts", role: .destructive) {
                    editor.autoDetect(pendingSensitivity)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Auto-detect starts over, so your current cuts, section names, and keep/discard choices will be replaced.")
            }
        }
    }

    // MARK: - Fixed top area

    private func header(wide: Bool) -> some View {
        VStack(spacing: 10) {
            WaveformView(
                peaks: model.peaks,
                overviewSecondsPerBucket: model.secondsPerBucket,
                loudest: model.loudestPeak,
                detail: editor.detail,
                duration: model.duration,
                viewStart: editor.viewStart,
                viewDuration: editor.viewDuration,
                currentTime: player.currentTime,
                markerTimes: editor.markers.map { $0.time },
                dimmedRanges: editor.discardedRanges,
                onSeek: { player.scrub(to: $0, final: true) },
                onScrub: { time, isFinal in player.scrub(to: time, final: isFinal) },
                onPan: { fraction, isFinal in editor.pan(fraction: fraction, final: isFinal) },
                onPinch: { scale, isFinal in editor.pinch(scale: scale, final: isFinal) }
            )
            .frame(height: wide ? 220 : 120)

            HStack(spacing: 14) {
                Text(TimeFormat.clock(player.currentTime, precise: true))
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    editor.zoomStep(zoomIn: false, playhead: player.currentTime)
                } label: {
                    Image(systemName: "minus.magnifyingglass").font(.title3)
                }
                .accessibilityLabel("Zoom out")
                Button {
                    editor.zoomStep(zoomIn: true, playhead: player.currentTime)
                } label: {
                    Image(systemName: "plus.magnifyingglass").font(.title3)
                }
                .accessibilityLabel("Zoom in")
                Button {
                    editor.centerOn(player.currentTime)
                } label: {
                    Image(systemName: "scope").font(.title3)
                }
                .accessibilityLabel("Scroll to playhead")
                Spacer()
                Text(TimeFormat.clock(model.duration))
                    .foregroundStyle(.secondary)
            }
            .font(.footnote.monospacedDigit())

            HStack(spacing: 22) {
                Spacer()
                skipButton(symbol: "gobackward.15", delta: -15, label: "Back 15 seconds")
                skipButton(symbol: "gobackward.5", delta: -5, label: "Back 5 seconds")
                Button {
                    player.togglePlay()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 46))
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                .keyboardShortcut(.space, modifiers: [])
                skipButton(symbol: "goforward.5", delta: 5, label: "Forward 5 seconds")
                skipButton(symbol: "goforward.15", delta: 15, label: "Forward 15 seconds")
                Spacer()
            }

            Button {
                editor.addMarker(at: player.currentTime)
            } label: {
                Label("Add cut at playhead", systemImage: "scissors")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(amber)
            .keyboardShortcut("c", modifiers: [])
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func skipButton(symbol: String, delta: Double, label: String) -> some View {
        Button {
            player.skip(by: delta)
        } label: {
            Image(systemName: symbol).font(.title2)
        }
        .accessibilityLabel(label)
        // Keyboard: ← → skip 5 seconds, Shift + ← → skip 15.
        .keyboardShortcut(
            delta < 0 ? KeyEquivalent.leftArrow : KeyEquivalent.rightArrow,
            modifiers: abs(delta) > 5 ? [.shift] : []
        )
    }

    // MARK: - Scrolling lists

    /// Wide screens: cut points on the left, sections and export on the right.
    private func wideLists(sections: [CutSection], keptCount: Int) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                cutsContent
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
            }
            Divider()
            ScrollView {
                VStack(spacing: 8) {
                    sectionsContent(sections: sections, keptCount: keptCount)
                    footer
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func list(sections: [CutSection], keptCount: Int) -> some View {
        ScrollView {
            VStack(spacing: 8) {
                switch tab {
                case .cuts:
                    cutsContent
                case .sections:
                    sectionsContent(sections: sections, keptCount: keptCount)
                }
                footer
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var cutsContent: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Cut points")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(DetectSensitivity.allCases) { sensitivity in
                        Button(sensitivity.label) {
                            requestAutoDetect(sensitivity)
                        }
                    }
                } label: {
                    Label("Auto-detect", systemImage: "wand.and.stars")
                        .font(.footnote.weight(.semibold))
                }
            }

            if editor.markers.isEmpty {
                Text("No cuts yet. Play the recording and tap “Add cut at playhead” wherever one song ends and the next begins, or try Auto-detect to place cuts after applause.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }

            ForEach(Array(editor.markers.enumerated()), id: \.element.id) { index, marker in
                MarkerRow(
                    number: index + 1,
                    time: marker.time,
                    onPlay: {
                        editor.resumeFollowing()
                        player.play(from: marker.time)
                    },
                    onNudge: { delta in editor.nudgeMarker(id: marker.id, by: delta) },
                    onDelete: { editor.removeMarker(id: marker.id) }
                )
            }
        }
    }

    private func sectionsContent(sections: [CutSection], keptCount: Int) -> some View {
        VStack(spacing: 8) {
            Text("\(keptCount) of \(sections.count) sections will be exported. Discarded sections are dimmed on the waveform.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(sections) { section in
                SectionRow(
                    section: section,
                    onRename: { editor.setName($0, for: section.id) },
                    onToggleKeep: { editor.toggleKeep(id: section.id) },
                    onPreview: {
                        editor.frame(start: section.start, end: section.end)
                        player.preview(from: section.start, to: section.end)
                    }
                )
            }

            ExportPanel(exporter: exporter, keptCount: keptCount) { options in
                guard let url = model.fileURL else { return }
                player.pause()
                exporter.export(source: url, sections: sections, options: options)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.fileName).font(.subheadline.weight(.semibold))
            Text("\(TimeFormat.clock(model.duration)) · \(String(format: "%.0f", model.fileSizeMB)) MB · \(Int(model.sampleRate)) Hz · \(model.channelCount == 1 ? "mono" : "\(model.channelCount) channels")")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Import another recording", action: chooseAnother)
                .buttonStyle(.bordered)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 18)
    }

    private func requestAutoDetect(_ sensitivity: DetectSensitivity) {
        if editor.markers.isEmpty {
            editor.autoDetect(sensitivity)
        } else {
            pendingSensitivity = sensitivity
            showReplaceConfirm = true
        }
    }
}

/// One line in the cut point list.
struct MarkerRow: View {
    let number: Int
    let time: Double
    let onPlay: () -> Void
    let onNudge: (Double) -> Void
    let onDelete: () -> Void

    private let amber = Color(red: 0.89, green: 0.63, blue: 0.24)
    private let mint = Color(red: 0.33, green: 0.79, blue: 0.64)

    var body: some View {
        HStack(spacing: 6) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .frame(width: 22, height: 22)
                .background(Circle().fill(amber))

            Text(TimeFormat.clock(time, precise: true))
                .font(.system(.footnote, design: .monospaced).weight(.semibold))
                .foregroundStyle(amber)
                .frame(width: 58, alignment: .leading)

            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.black)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(mint))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play from cut \(number)")

            nudgeButton("−1s", -1)
            nudgeButton("−.1", -0.1)
            nudgeButton("+.1", 0.1)
            nudgeButton("+1s", 1)

            Spacer(minLength: 0)

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 28, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete cut \(number)")
        }
        .padding(8)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func nudgeButton(_ label: String, _ delta: Double) -> some View {
        Button {
            onNudge(delta)
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 30)
                .background(Color(.tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

/// One card in the sections list: name, keep/discard, time range, preview.
struct SectionRow: View {
    let section: CutSection
    let onRename: (String) -> Void
    let onToggleKeep: () -> Void
    let onPreview: () -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    private let amber = Color(red: 0.89, green: 0.63, blue: 0.24)
    private let mint = Color(red: 0.33, green: 0.79, blue: 0.64)

    init(
        section: CutSection,
        onRename: @escaping (String) -> Void,
        onToggleKeep: @escaping () -> Void,
        onPreview: @escaping () -> Void
    ) {
        self.section = section
        self.onRename = onRename
        self.onToggleKeep = onToggleKeep
        self.onPreview = onPreview
        _text = State(initialValue: section.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                badge

                TextField("Name", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .submitLabel(.done)
                    .disabled(!section.keep)
                    .onSubmit { onRename(text) }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { onRename(text) }
                    }
                    .onChange(of: section.name) { _, newName in
                        if !focused { text = newName }
                    }

                Button(action: onToggleKeep) {
                    Text(section.keep ? "Keep" : "Discard")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(section.keep ? Color.black : Color.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(section.keep ? mint : Color(.tertiarySystemFill))
                        )
                }
                .buttonStyle(.plain)
            }

            HStack {
                Text("\(TimeFormat.clock(section.start)) – \(TimeFormat.clock(section.end)) (\(TimeFormat.clock(section.end - section.start)))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onPreview) {
                    Label("Preview", systemImage: "play.fill")
                        .font(.footnote)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(section.keep ? mint : Color(.tertiarySystemFill))
                .frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .opacity(section.keep ? 1 : 0.55)
    }

    /// The number of the cut this section starts at, so the two lists line up.
    @ViewBuilder
    private var badge: some View {
        if let number = section.startCutNumber {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .frame(width: 24, height: 24)
                .background(Circle().fill(amber))
        } else {
            Text("•")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color(.tertiarySystemFill)))
        }
    }
}
