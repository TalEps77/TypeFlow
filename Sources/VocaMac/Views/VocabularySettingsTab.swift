// VocabularySettingsTab.swift
// VocaMac
//
// Create, edit, and delete Dictionary Entries and Snippets; export/import
// each as JSON (Story 5.3, Story 5.5). One file per tab, following the
// ProfilesSettingsTab precedent.
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
    @State private var editingSnippet: Snippet?
    @State private var importErrorMessage: String?

    var body: some View {
        Form {
            Section("Dictionary") {
                Toggle("Automatically fix recurring mis-transcriptions", isOn: $appState.dictionaryEnabled)

                Text("The Dictionary corrects your transcript after Whisper has already produced it — exact and near-miss spellings of a term you add are swapped for the canonical form you choose. This is separate from the Vocabulary field on the General tab, which instead nudges Whisper's decoder before transcription; adding a Dictionary Entry never changes that field, and vice versa.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Correction Learning") {
                Toggle("Notice when I hand-correct a word and suggest a Dictionary Entry", isOn: $appState.correctionLearningEnabled)

                Text("Off by default. When on, VocaMac briefly re-reads the text field you just dictated into to see if you retyped a single word — nothing else about that field is ever saved, logged, or sent anywhere. A correction is only ever suggested below for you to approve or dismiss; it never adds itself to the Dictionary silently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !appState.pendingCorrectionCandidates.isEmpty {
                    ForEach(appState.pendingCorrectionCandidates, id: \.self) { candidate in
                        CorrectionCandidateRow(candidate: candidate) {
                            appState.confirmCorrectionCandidate(candidate)
                        } onDismiss: {
                            appState.dismissCorrectionCandidate(candidate)
                        }
                    }
                }
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

            Section("Snippets") {
                Toggle("Expand spoken Cues into fixed text blocks", isOn: $appState.snippetsEnabled)

                Text("Say a Cue anywhere in a dictation and it's replaced with the Snippet's body — verbatim, line breaks included, and never rewritten by cleanup (AD-3). Snippets expand even with the Cleanup tab's post-processing off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Manage Snippets") {
                List {
                    ForEach(appState.snippetStore.snippets) { snippet in
                        SnippetRow(snippet: snippet) {
                            editingSnippet = snippet
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            appState.snippetStore.delete(appState.snippetStore.snippets[index].id)
                        }
                    }
                }
                .frame(minHeight: 180, maxHeight: 260)

                Button {
                    let new = Snippet(cue: "", body: "")
                    appState.snippetStore.add(new)
                    editingSnippet = new
                } label: {
                    Label("Add Snippet", systemImage: "plus")
                }
                .controlSize(.small)
            }

            Section("Snippet Backup") {
                HStack(spacing: 12) {
                    Button("Export…") { exportSnippets() }
                    Button("Import…") { importSnippets() }
                }

                Text("Export writes every Snippet to a single JSON file, alongside Profiles and the Dictionary (AD-9/FR-20). Import replaces your current Snippets with the ones in the chosen file — a malformed file is rejected and your existing Snippets are left untouched.")
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
        .sheet(item: $editingSnippet) { snippet in
            SnippetEditorView(
                snippet: snippet,
                hasCollision: { cue in appState.snippetStore.hasCollision(withCue: cue, excluding: snippet.id) }
            ) { updated in
                appState.snippetStore.update(updated)
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

    // MARK: - Export / Import (Story 5.5 AC)

    private func exportSnippets() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "VocaMac-Snippets.json"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(appState.snippetStore.snippets)
                try data.write(to: url, options: .atomic)
            } catch {
                VocaLogger.error(.snippets, "Snippet export failed: \(error.localizedDescription)")
                importErrorMessage = "Could not write the export file: \(error.localizedDescription)"
            }
        }
    }

    private func importSnippets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                let imported = try JSONDecoder().decode([Snippet].self, from: data)
                appState.snippetStore.replaceAll(with: imported)
            } catch {
                importErrorMessage = "That file isn't a valid VocaMac Snippets export: \(error.localizedDescription)"
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
                    HStack(spacing: 6) {
                        Text(entry.canonicalForm.isEmpty ? "(untitled)" : entry.canonicalForm)
                        if entry.learned {
                            Text("Learned")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.secondary.opacity(0.2))
                                .cornerRadius(4)
                        }
                    }
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

// MARK: - Correction candidate row

private struct CorrectionCandidateRow: View {
    let candidate: CorrectionCandidate
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\"\(candidate.original)\" → \"\(candidate.corrected)\"")
                Text("Add to Dictionary?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Dismiss", action: onDismiss)
                .controlSize(.small)
            Button("Add", action: onConfirm)
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
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

// MARK: - Snippet row

private struct SnippetRow: View {
    let snippet: Snippet
    let onTap: () -> Void

    private var bodyPreview: String {
        let firstLine = snippet.body.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return firstLine.isEmpty ? "Empty body" : firstLine
    }

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snippet.cue.isEmpty ? "(untitled cue)" : snippet.cue)
                    Text(bodyPreview)
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

// MARK: - Snippet editor

private struct SnippetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var snippet: Snippet
    @State private var collisionMessage: String?
    private let hasCollision: (String) -> Bool
    private let onSave: (Snippet) -> Void

    init(snippet: Snippet, hasCollision: @escaping (String) -> Bool, onSave: @escaping (Snippet) -> Void) {
        _snippet = State(initialValue: snippet)
        self.hasCollision = hasCollision
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section("Cue") {
                TextField("e.g. \"add my signature\"", text: $snippet.cue)
                    .onChange(of: snippet.cue) { _ in collisionMessage = nil }

                if let collisionMessage {
                    Text(collisionMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("Spoken to trigger expansion — matched case-insensitively and tolerant of niqqud/spelling variance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Body") {
                TextEditor(text: $snippet.body)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 160)
                    .border(Color.secondary.opacity(0.3))

                Text("Preserved exactly, including line breaks — never seen or rewritten by post-processing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    // Story 5.5 AC: a Cue colliding with an existing one is
                    // rejected with a clear message, not saved silently.
                    guard !hasCollision(snippet.cue) else {
                        collisionMessage = "Another Snippet already uses this Cue — Cues must be unique."
                        return
                    }
                    onSave(snippet)
                    dismiss()
                }
                .disabled(snippet.cue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
