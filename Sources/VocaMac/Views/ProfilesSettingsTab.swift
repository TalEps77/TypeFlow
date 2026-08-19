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

    @State private var editingProfile: Profile?
    @State private var importErrorMessage: String?

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

            Section("Manage") {
                List {
                    ForEach(appState.profileStore.profiles) { profile in
                        ProfileRow(profile: profile) {
                            editingProfile = profile
                        }
                    }
                    .onMove { offsets, destination in
                        appState.profileStore.move(fromOffsets: offsets, toOffset: destination)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            // A no-op for the Default Profile — ProfileStore
                            // refuses to delete it (Story 4.2 AC).
                            appState.profileStore.delete(appState.profileStore.profiles[index].id)
                        }
                    }
                }
                .frame(minHeight: 180, maxHeight: 260)

                Button {
                    let new = Profile(name: "New Profile")
                    appState.profileStore.add(new)
                    editingProfile = new
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
        .sheet(item: $editingProfile) { profile in
            ProfileEditorView(profile: profile) { updated in
                appState.profileStore.update(updated)
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
                importErrorMessage = "Could not write the export file: \(error.localizedDescription)"
            }
        }
    }

    private func importProfiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                let imported = try JSONDecoder().decode([Profile].self, from: data)
                guard !imported.isEmpty else {
                    importErrorMessage = "That file contains no Profiles."
                    return
                }
                // ProfileStore.replaceAll always keeps exactly one Default
                // Profile, even if the imported file omitted or duplicated
                // it — existing Profiles are only touched once decoding has
                // fully succeeded, never on a partial or malformed read.
                appState.profileStore.replaceAll(with: imported)
            } catch {
                importErrorMessage = "That file isn't a valid VocaMac Profiles export: \(error.localizedDescription)"
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
