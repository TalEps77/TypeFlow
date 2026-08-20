// ProfilesSettingsTab.swift
// VocaMac
//
// Create, edit, reorder, and delete Profiles; export/import as JSON
// (Story 4.3). One file per tab, following the PostProcessSettingsTab
// precedent.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ProfilesSettingsTab: View {
    @EnvironmentObject var appState: AppState

    /// What the editor sheet is currently editing, and whether it is a
    /// Profile that exists yet. A brand-new Profile is *not* added to the
    /// store until Done is pressed (MINOR 5) — the old flow added it first
    /// and opened the editor on it, so cancelling left an orphan "New
    /// Profile" behind that the user then had to delete by hand.
    private struct EditorRequest: Identifiable {
        let profile: Profile
        let isNew: Bool
        var id: UUID { profile.id }
    }

    @State private var editorRequest: EditorRequest?
    @State private var importErrorMessage: String?
    /// Separate from `importErrorMessage` (MINOR 6): an export that failed to
    /// write used to be reported under an "Import Failed" alert, which is
    /// both wrong and alarming — it reads as though the file being exported
    /// to had damaged something.
    @State private var exportErrorMessage: String?
    /// Set when an import turned Cursor Context off on Profiles that asked
    /// for it, so the user is told rather than silently overridden (MAJOR 5).
    @State private var importNoticeMessage: String?

    var body: some View {
        Form {
            Section("Profiles") {
                Toggle("Use Profiles to tailor dictation per app", isOn: $appState.profilesEnabled)

                Text(appState.profilesEnabled
                     ? "Each dictation is shaped by the Profile bound to the frontmost app when you started speaking, falling back to Default when nothing matches."
                     : "Every dictation uses the Default Profile — the same behavior as before Profiles existed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cursor Context") {
                Toggle("Read text near the cursor to match its style", isOn: $appState.contextCaptureEnabled)

                Text("When on, TypeFlow reads a small amount of text immediately before and after your cursor in the app you're dictating into — so the LLM can match its existing tone, punctuation, and formatting. This text is sent to the LLM for that one request only: it is never saved to History, never written to a log, and never stored anywhere. This also requires the Profile you're dictating into to have its own \"Read text around the cursor\" toggle on — both must be on for anything to be read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Manage") {
                List {
                    ForEach(appState.profileStore.profiles) { profile in
                        ProfileRow(profile: profile) {
                            editorRequest = EditorRequest(profile: profile, isNew: false)
                        }
                    }
                    .onMove { offsets, destination in
                        appState.profileStore.move(fromOffsets: offsets, toOffset: destination)
                    }
                    .onDelete { offsets in
                        // Resolve every id *before* deleting any of them
                        // (BLOCKER 2): `delete` mutates the same array these
                        // offsets index into, so deleting inside the loop
                        // makes each later offset point at the wrong Profile
                        // — or past the end of the array entirely, which
                        // traps. Multi-row deletion is reachable from a
                        // normal Edit-mode selection, not an exotic path.
                        let ids = offsets.compactMap { index -> UUID? in
                            guard appState.profileStore.profiles.indices.contains(index) else { return nil }
                            return appState.profileStore.profiles[index].id
                        }
                        // A no-op for the Default Profile — ProfileStore
                        // refuses to delete it (Story 4.2 AC).
                        ids.forEach { appState.profileStore.delete($0) }
                    }
                }
                .frame(minHeight: 180, maxHeight: 260)

                Text("When two Profiles claim the same app, the one higher in this list wins — drag to reorder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    // Not added to the store until Done (MINOR 5).
                    editorRequest = EditorRequest(profile: Profile(name: "New Profile"), isNew: true)
                } label: {
                    Label("Add Profile", systemImage: "plus")
                }
                .controlSize(.small)
            }

            Section("Backup") {
                HStack(spacing: 12) {
                    Button("Export…") { exportProfiles() }
                    Button("Import…") { importProfiles() }
                }

                Text("Export writes every Profile to a single JSON file (AD-9/FR-13). Import replaces your current Profiles with the ones in the chosen file — a malformed file is rejected and your existing Profiles are left untouched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editorRequest) { request in
            ProfileEditorView(profile: request.profile) { updated in
                if request.isNew {
                    appState.profileStore.add(updated)
                } else {
                    appState.profileStore.update(updated)
                }
            }
        }
        .alert("Import Failed", isPresented: Binding(
            get: { importErrorMessage != nil },
            set: { isPresented in if !isPresented { importErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importErrorMessage ?? "")
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportErrorMessage != nil },
            set: { isPresented in if !isPresented { exportErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportErrorMessage ?? "")
        }
        .alert("Profiles Imported", isPresented: Binding(
            get: { importNoticeMessage != nil },
            set: { isPresented in if !isPresented { importNoticeMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importNoticeMessage ?? "")
        }
    }

    // MARK: - Export / Import (Story 4.3 AC)

    private func exportProfiles() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "VocaMac-Profiles.json"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(appState.profileStore.profiles)
                try data.write(to: url, options: .atomic)
            } catch {
                VocaLogger.error(.profiles, "Profile export failed: \(error.localizedDescription)")
                exportErrorMessage = "Could not write the export file: \(error.localizedDescription)"
            }
        }
    }

    /// A Profiles export of any realistic size is a few kilobytes. Reading a
    /// user-chosen file with `Data(contentsOf:)` is otherwise unbounded — a
    /// mis-picked disk image or video would be pulled into memory whole
    /// before `JSONDecoder` ever got the chance to reject it (MAJOR 5).
    private static let maximumImportBytes = 5_000_000

    private func importProfiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard fileSize <= Self.maximumImportBytes else {
                    importErrorMessage = "That file is too large to be a TypeFlow Profiles export."
                    return
                }

                let data = try Data(contentsOf: url)
                let imported = try JSONDecoder().decode([Profile].self, from: data)
                guard !imported.isEmpty else {
                    importErrorMessage = "That file contains no Profiles."
                    return
                }

                // A Profiles file is user-editable and routinely shared, so
                // it is treated as untrusted input rather than as data this
                // app wrote (MAJOR 5): `sanitizedForImport` coerces exactly
                // one unbound Default Profile, drops duplicate ids, and — the
                // load-bearing part — refuses to let a file arm Cursor
                // Context on any Profile. Existing Profiles are still only
                // touched once decoding has fully succeeded, never on a
                // partial or malformed read.
                let sanitized = appState.profileStore.replaceAll(with: imported)

                if !sanitized.contextCaptureRequestedBy.isEmpty {
                    let names = sanitized.contextCaptureRequestedBy.joined(separator: ", ")
                    importNoticeMessage = """
                    \(sanitized.profiles.count) Profiles were imported.

                    "Read text around the cursor" was turned off on every imported Profile that asked for it (\(names)). Reading your documents is never something an imported file can switch on — turn it back on yourself, per Profile, if that is what you want.
                    """
                }
            } catch {
                importErrorMessage = "That file isn't a valid TypeFlow Profiles export: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Profile row

private struct ProfileRow: View {
    let profile: Profile
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(profile.name)
                        if profile.isDefault {
                            Text("Default")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.secondary.opacity(0.2))
                                .cornerRadius(4)
                        }
                    }
                    Text(profile.bundleIdentifiers.isEmpty ? "No apps bound — fallback" : profile.bundleIdentifiers.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Profile editor

private struct ProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profile: Profile
    @State private var selectedRunningApp = ""
    private let onSave: (Profile) -> Void

    init(profile: Profile, onSave: @escaping (Profile) -> Void) {
        _profile = State(initialValue: profile)
        self.onSave = onSave
    }

    /// Currently-running, regular (Dock-visible) applications, so a bundle
    /// identifier can be picked instead of typed by hand (Story 4.3 AC).
    private var runningApplications: [(name: String, bundleIdentifier: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (name: String, bundleIdentifier: String)? in
                guard let bundleIdentifier = app.bundleIdentifier, let name = app.localizedName else { return nil }
                return (name: name, bundleIdentifier: bundleIdentifier)
            }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Profile name", text: $profile.name)
            }

            Section("Applications") {
                if profile.isDefault {
                    Text("The Default Profile has no bound applications — it's the fallback used when nothing else matches.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(profile.bundleIdentifiers, id: \.self) { bundleIdentifier in
                        HStack {
                            Text(bundleIdentifier)
                                .textSelection(.enabled)
                            Spacer()
                            Button {
                                profile.bundleIdentifiers.removeAll { $0 == bundleIdentifier }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                    }

                    Picker("Add a running app…", selection: $selectedRunningApp) {
                        Text("Choose an app").tag("")
                        ForEach(runningApplications, id: \.bundleIdentifier) { app in
                            Text("\(app.name) — \(app.bundleIdentifier)").tag(app.bundleIdentifier)
                        }
                    }
                    .onChange(of: selectedRunningApp) { newValue in
                        guard !newValue.isEmpty, !profile.bundleIdentifiers.contains(newValue) else { return }
                        profile.bundleIdentifiers.append(newValue)
                        selectedRunningApp = ""
                    }
                }
            }

            Section("Prompt Override") {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $profile.promptOverride)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 120)
                        .border(Color.secondary.opacity(0.3))

                    if profile.promptOverride.isEmpty {
                        Text("Empty — the global system prompt (Cleanup tab) is used for this Profile.")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }

                Text("When set, this replaces the global system prompt entirely for dictations resolved to this Profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // MAJOR 7: the safety check that keeps the LLM from answering
                // a transcript instead of cleaning it is tuned for cleanup —
                // it compares the answer's length and character overlap
                // against the transcript. A prompt that asks for a genuine
                // transformation fails it every single time, and the user
                // sees their raw transcript with nothing to explain why. Say
                // so here, where the prompt is written, rather than leaving
                // it to be discovered.
                Text("Only cleanup-style prompts take effect. A safety check compares the model's answer against the transcript and rejects anything that is not recognizably the same text — so an override that asks to translate, summarize, expand, or rewrite will be rejected every time and you will get the raw transcript instead. Tone, punctuation, formatting, and filler removal are what this is for. Rejections are visible in History: the dictation is marked as having fallen back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Features") {
                Toggle("Clean transcripts with the LLM for this Profile", isOn: $profile.postProcessEnabled)
                Toggle("Read text around the cursor for this Profile", isOn: $profile.contextCaptureEnabled)

                Text("Both post-processing and Cursor Context also require their matching global toggle to be on — a Profile can only narrow a feature further, never turn on one that's off globally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 500)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    onSave(profile)
                    dismiss()
                }
                .disabled(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
