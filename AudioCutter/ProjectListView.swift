import SwiftUI

/// The start screen: every project on this phone, with a way to add or delete them.
struct ProjectListView: View {
    @ObservedObject var model: RecordingModel
    let onImport: () -> Void

    @State private var pendingDelete: ProjectInfo?

    private let mint = Color(red: 0.33, green: 0.79, blue: 0.64)

    private var totalBytes: Int64 {
        model.projects.reduce(0) { $0 + $1.sizeBytes }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Button(action: onImport) {
                    Label("Import new recording", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(mint)

                Text("In Voice Memos, tap Share → Save to Files first, then pick the file here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()

            if model.projects.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("No projects yet")
                        .font(.headline)
                    Text("Each recording you import becomes a project, with its own cuts and names saved on this phone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .padding(.horizontal, 32)
            } else {
                List {
                    Section {
                        ForEach(model.projects) { project in
                            Button {
                                model.open(project)
                            } label: {
                                row(project)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDelete = project
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    pendingDelete = project
                                } label: {
                                    Label("Delete project", systemImage: "trash")
                                }
                            }
                        }
                    } footer: {
                        Text("\(model.projects.count) project\(model.projects.count == 1 ? "" : "s") · \(sizeText(totalBytes)) used. Swipe left on a project to delete it and free up space.")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .confirmationDialog(
            "Delete this project?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { project in
            Button("Delete “\(project.name)”", role: .destructive) {
                model.delete(project)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { project in
            Text("This permanently removes the recording and its cuts from this phone and frees \(sizeText(project.sizeBytes)). Songs you've already exported and saved to Files aren't affected.")
        }
    }

    private func row(_ project: ProjectInfo) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text("\(TimeFormat.clock(project.duration)) · \(project.cutCount) cut\(project.cutCount == 1 ? "" : "s") · \(sizeText(project.sizeBytes))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Edited \(relative(project.modifiedAt))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func relative(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}
