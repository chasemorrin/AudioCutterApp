import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = RecordingModel()
    @StateObject private var player = PlayerController()
    @StateObject private var editor = EditorModel()
    @State private var showImporter = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            screen
                .navigationTitle(isReady ? (model.current?.name ?? "Audio Cutter") : "Audio Cutter")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            switchProject()
                        } label: {
                            Label("Projects", systemImage: "folder")
                                .labelStyle(.titleAndIcon)
                        }
                        .disabled(!isReady)
                        .opacity(isReady ? 1 : 0)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            editor.undo()
                        } label: {
                            Label("Undo", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(!isReady || !editor.canUndo)
                        .opacity(isReady ? 1 : 0)
                        .keyboardShortcut("z", modifiers: .command)
                    }
                }
                .fileImporter(
                    isPresented: $showImporter,
                    allowedContentTypes: [.audio]
                ) { result in
                    switch result {
                    case .success(let url):
                        saveAndPause()
                        model.importRecording(from: url)
                    case .failure(let error):
                        model.phase = .failed(error.localizedDescription)
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    // Save right away when leaving the app, in case it gets closed.
                    if newPhase != .active, isReady {
                        editor.save(playhead: player.currentTime)
                    }
                }
                .task(id: model.fileURL) {
                    if let url = model.fileURL, let project = model.current {
                        player.load(url: url, duration: model.duration)
                        editor.load(
                            url: url,
                            duration: model.duration,
                            overviewSecondsPerBucket: model.secondsPerBucket,
                            activity: model.activity,
                            saved: ProjectStore.loadEdits(project.id),
                            projectID: project.id
                        )
                        if editor.restoredPlayhead > 0 {
                            player.scrub(to: editor.restoredPlayhead, final: true)
                        }
                    }
                }
        }
    }

    private var isReady: Bool {
        if case .ready = model.phase { return true }
        return false
    }

    /// Saves the open project and stops playback.
    private func saveAndPause() {
        if isReady {
            editor.save(playhead: player.currentTime)
        }
        player.pause()
    }

    private func switchProject() {
        saveAndPause()
        model.closeProject()
    }

    @ViewBuilder
    private var screen: some View {
        switch model.phase {
        case .idle:
            ProjectListView(model: model) { showImporter = true }

        case .analyzing(let fraction):
            simple {
                Text("Reading recording…")
                ProgressView(value: fraction)
                Text("\(Int(fraction * 100))%")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .ready:
            EditorView(
                model: model,
                player: player,
                editor: editor,
                chooseAnother: { showImporter = true }
            )

        case .failed(let message):
            simple {
                Text("Couldn't open that file")
                    .font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                Button("Back to projects") { model.closeProject() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func simple<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            content()
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    ContentView()
}
