// VocabularySettingsTab.swift
// VocaMac
//
// Create, edit, and delete Dictionary Entries; export/import as JSON
// (Story 5.3). Hosts Snippets too from Story 5.5 onward. One file per tab,
// following the ProfilesSettingsTab precedent.
//
// Distinct from the existing Vocabulary field (General tab,
// `AppState.customVocabulary`, sent to Whisper as a "Glossary: " prompt
// *before* transcription to bias the decoder): the Dictionary here corrects
// the transcript *after* the fact (NFR-5) and is never read or written by
// that mechanism.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct VocabularySettingsTab: View {
    @EnvironmentObject var appState: AppState

    @State private var editingEntry: DictionaryEntry?
    @State private var importErrorMessage: String?

    var body: some View {
        Form {
            Section("Dictionary") {
                Toggle("Automatically fix recurring mis-transcriptions", isOn: $appState.dictionaryEnabled)

                Text("The Dictionary corrects your transcript after Whisper has already produced it — exact and near-miss spellings of a term you add are swapped for the canonical form you choose. This is separate from the Vocabulary field on the General tab, which instead nudges Whisper's decoder before transcription; adding a Dictionary Entry never changes that field, and vice versa.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Manage") {
                List {
                    ForEach(appState.dictionaryStore.entries) { entry in
                        DictionaryEntryRow(entry: entry) {
                            editingEntry = entry
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            appState.dictionaryStore.delete(appState.dictionaryStore.entries[index].id)
                        }
                    }
                }
                .frame(minHeight: 180, maxHeight: 260)

                Button {
                    let new = DictionaryEntry(canonicalForm: "", triggers: [])
                    appState.dictionaryStore.add(new)
                    editingEntry = new
                } label: {
                    Label("Add Entry", systemImage: "plus")
                }
                .controlSize(.small)
            }

            Section("Backup") {
                HStack(spacing: 12) {
                    Button("Export…") { exportEntries() }
                    Button("Import…") { importEntries() }
                }

                Text("Export writes every Dictionary Entry to a single JSON file, alongside Profiles (AD-9/FR-17). Import replaces your current Dictionary with the ones in the chosen file — a malformed file is rejected and your existing entries are left untouched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingEntry) { entry in
            DictionaryEntryEditorView(entry: entry) { updated in
                appState.dictionaryStore.update(updated)
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

    // MARK: - Export / Import (Story 5.3 AC)

    private func exportEntries() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "VocaMac-Dictionary.json"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(appState.dictionaryStore.entries)
                try data.write(to: url, options: .atomic)
            } catch {
                VocaLogger.error(.dictionary, "Dictionary export failed: \(error.localizedDescription)")
                importErrorMessage = "Could not write the export file: \(error.localizedDescription)"
            }
        }
    }

    private func importEntries() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                let imported = try JSONDecoder().decode([DictionaryEntry].self, from: data)
                appState.dictionaryStore.replaceAll(with: imported)
            } catch {
                importErrorMessage = "That file isn't a valid VocaMac Dictionary export: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Entry row

private struct DictionaryEntryRow: View {
    let entry: DictionaryEntry
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.canonicalForm.isEmpty ? "(untitled)" : entry.canonicalForm)
                    Text(entry.triggers.isEmpty ? "No triggers yet" : entry.triggers.joined(separator: ", "))
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

// MARK: - Entry editor

private struct DictionaryEntryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entry: DictionaryEntry
    @State private var newTrigger = ""
    private let onSave: (DictionaryEntry) -> Void

    init(entry: DictionaryEntry, onSave: @escaping (DictionaryEntry) -> Void) {
        _entry = State(initialValue: entry)
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section("Canonical Form") {
                TextField("e.g. Kubernetes", text: $entry.canonicalForm)
            }

            Section("Triggers") {
                ForEach(entry.triggers, id: \.self) { trigger in
                    HStack {
                        Text(trigger)
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            entry.triggers.removeAll { $0 == trigger }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                    }
                }

                HStack {
                    TextField("Add a mis-transcribed variant", text: $newTrigger)
                        .onSubmit(addTrigger)
                    Button("Add", action: addTrigger)
                        .disabled(newTrigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Text("Each trigger is a spelling Whisper is known to produce for this term — an exact one, or one close enough to auto-correct.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    onSave(entry)
                    dismiss()
                }
                .disabled(entry.canonicalForm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || entry.triggers.isEmpty)
            }
        }
    }

    private func addTrigger() {
        let trimmed = newTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !entry.triggers.contains(trimmed) else { return }
        entry.triggers.append(trimmed)
        newTrigger = ""
    }
}
