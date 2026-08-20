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
    /// Separate from `importErrorMessage` (MINOR 2): a failed *export* was
    /// reported under an "Import Failed" heading, telling the user their
    /// import went wrong when they had asked to save a file.
    @State private var exportErrorMessage: String?
    @State private var importSummaryMessage: String?

    /// Refuses an import file larger than this before reading a byte of it
    /// (MAJOR 5). A Dictionary export is kilobytes; anything at this scale is a
    /// mistaken file, and `Data(contentsOf:)` would otherwise pull all of it
    /// into memory.
    private static let maximumImportBytes = 5 * 1024 * 1024

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

                Text("Off by default. When on, TypeFlow briefly re-reads the text field you just dictated into to see if you retyped a single word — nothing else about that field is ever saved, logged, or sent anywhere. A correction is only ever suggested below for you to approve or dismiss; it never adds itself to the Dictionary silently.")
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

                // MAJOR 9: the only place the dismissal list is visible at all,
                // and the only way to get rid of it. Data VocaMac keeps on the
                // user's behalf must be something they can clear without
                // deleting the application support directory by hand.
                HStack {
                    Button("Clear Dismissed Corrections") {
                        appState.dismissedCorrectionsStore.clear()
                    }
                    .controlSize(.small)
                    .disabled(appState.dismissedCorrectionsStore.dismissed.isEmpty)
                    Text("\(appState.dismissedCorrectionsStore.dismissed.count) remembered")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Dismissals are stored as one-way hashes — the words themselves are never written to disk — so that saying \"no\" to a suggestion costs less privacy than saying yes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Manage") {
                // A `List` here (as this Section used before) never scrolls
                // on its own once embedded in this Form: all rows still
                // render (confirmed via the accessibility tree — every entry
                // is present as a row), but a scroll gesture over the clipped
                // region is captured by the outer Form's own scroll view
                // instead, which just jumps past the whole clipped block.
                // Past a handful of entries, everything below the fold was
                // permanently unreachable. `ScrollView` + `LazyVStack` is a
                // real, independently-scrolling NSScrollView, matching the
                // pattern already used for lists elsewhere in Settings (e.g.
                // `ModelSettingsTab`'s row list in SettingsView.swift).
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(appState.dictionaryStore.entries) { entry in
                            DictionaryEntryRow(entry: entry) {
                                editingEntry = entry
                            } onDelete: {
                                appState.dictionaryStore.delete(entry.id)
                            }
                            .padding(.vertical, 4)
                            // The ScrollView's own overlay scroll indicator sits
                            // right on top of the trailing edge, on top of
                            // DeleteRowButton's − button, making it unclickable
                            // (commit 53cc777 switched this list from `List` to
                            // `ScrollView`/`LazyVStack`, which does not reserve
                            // scrollbar gutter space the way `List` did). This
                            // padding gives the button room clear of that overlay.
                            .padding(.trailing, 14)

                            if entry.id != appState.dictionaryStore.entries.last?.id {
                                Divider()
                            }
                        }
                        .onDelete { offsets in
                            // BLOCKER 2: resolve every id *before* deleting any of
                            // them. Deleting inside the loop reindexes the array
                            // under the offsets still to be visited, so a
                            // multi-row delete removed the wrong rows — or trapped
                            // on an index past the end.
                            let ids = offsets.map { appState.dictionaryStore.entries[$0].id }
                            for id in ids {
                                appState.dictionaryStore.delete(id)
                            }
                        }
                    }
                }
                .frame(minHeight: 180, maxHeight: 260)

                Button {
                    // MAJOR 10: a draft, not a persisted row. Nothing reaches
                    // the store until the editor's Done, so Cancel leaves the
                    // Dictionary exactly as it was.
                    editingEntry = DictionaryEntry(canonicalForm: "", triggers: [])
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
                // Same non-scrolling `List`-in-`Form` issue as the Dictionary
                // list above, fixed the same way.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(appState.snippetStore.snippets) { snippet in
                            SnippetRow(snippet: snippet) {
                                editingSnippet = snippet
                            } onDelete: {
                                appState.snippetStore.delete(snippet.id)
                            }
                            .padding(.vertical, 4)
                            // Same overlay-scrollbar-over-the-delete-button issue
                            // as the Dictionary list above.
                            .padding(.trailing, 14)

                            if snippet.id != appState.snippetStore.snippets.last?.id {
                                Divider()
                            }
                        }
                        .onDelete { offsets in
                            // BLOCKER 2, same as the Dictionary list above.
                            let ids = offsets.map { appState.snippetStore.snippets[$0].id }
                            for id in ids {
                                appState.snippetStore.delete(id)
                            }
                        }
                    }
                }
                .frame(minHeight: 180, maxHeight: 260)

                Button {
                    editingSnippet = Snippet(cue: "", body: "")
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
                appState.dictionaryStore.upsert(updated)
            }
        }
        .sheet(item: $editingSnippet) { snippet in
            SnippetEditorView(
                snippet: snippet,
                hasCollision: { cue in appState.snippetStore.hasCollision(withCue: cue, excluding: snippet.id) }
            ) { updated in
                appState.snippetStore.upsert(updated)
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
        .alert("Import Complete", isPresented: Binding(
            get: { importSummaryMessage != nil },
            set: { isPresented in if !isPresented { importSummaryMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importSummaryMessage ?? "")
        }
    }

    // MARK: - Export / Import (Story 5.3 AC)

    private func exportEntries() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "TypeFlow-Dictionary.json"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(appState.dictionaryStore.entries)
                try data.write(to: url, options: .atomic)
            } catch {
                VocaLogger.error(.dictionary, "Dictionary export failed: \(error.localizedDescription)")
                exportErrorMessage = "Could not write the export file: \(error.localizedDescription)"
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
            Self.decodeOffMainThread([DictionaryEntry].self, from: url) { outcome in
                switch outcome {
                case .failure(let message):
                    importErrorMessage = message
                case .success(let imported):
                    let sanitized = DictionaryStore.sanitizedForImport(imported)
                    appState.dictionaryStore.replaceAll(with: sanitized.entries)
                    importSummaryMessage = Self.summary(
                        kept: sanitized.entries.count,
                        dropped: sanitized.dropped,
                        noun: "Dictionary Entry",
                        pluralNoun: "Dictionary Entries"
                    )
                }
            }
        }
    }

    // MARK: - Shared import plumbing (MAJOR 5)

    private enum ImportOutcome<Element> {
        case success([Element])
        case failure(String)
    }

    /// Reads and decodes an import file on a background queue, then hands the
    /// result back on the main actor (MAJOR 5).
    ///
    /// `Data(contentsOf:)` plus a JSON decode used to run inside the save
    /// panel's completion handler, which is the main thread — a large or
    /// pathological file stalled the whole UI. The size is checked from the
    /// file's metadata first, so an oversized file is refused without being
    /// read at all.
    private static func decodeOffMainThread<Element: Decodable>(
        _ type: [Element].Type,
        from url: URL,
        completion: @escaping @MainActor (ImportOutcome<Element>) -> Void
    ) {
        let maximumBytes = maximumImportBytes
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: ImportOutcome<Element>
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                if size > maximumBytes {
                    outcome = .failure("That file is \(size / 1024 / 1024)MB — far larger than any TypeFlow export, so it was not opened.")
                } else {
                    let data = try Data(contentsOf: url)
                    outcome = .success(try JSONDecoder().decode([Element].self, from: data))
                }
            } catch {
                outcome = .failure("That file isn't a valid TypeFlow export: \(error.localizedDescription)")
            }
            Task { @MainActor in completion(outcome) }
        }
    }

    private static func summary(kept: Int, dropped: Int, noun: String, pluralNoun: String) -> String {
        let keptText = "Imported \(kept) \(kept == 1 ? noun : pluralNoun)."
        guard dropped > 0 else { return keptText }
        return keptText + " \(dropped) \(dropped == 1 ? "entry was" : "entries were") skipped as incomplete or duplicated."
    }

    // MARK: - Export / Import (Story 5.5 AC)

    private func exportSnippets() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "TypeFlow-Snippets.json"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(appState.snippetStore.snippets)
                try data.write(to: url, options: .atomic)
            } catch {
                VocaLogger.error(.snippets, "Snippet export failed: \(error.localizedDescription)")
                exportErrorMessage = "Could not write the export file: \(error.localizedDescription)"
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
            Self.decodeOffMainThread([Snippet].self, from: url) { outcome in
                switch outcome {
                case .failure(let message):
                    importErrorMessage = message
                case .success(let imported):
                    let sanitized = SnippetStore.sanitizedForImport(imported)
                    appState.snippetStore.replaceAll(with: sanitized.snippets)
                    importSummaryMessage = Self.summary(
                        kept: sanitized.snippets.count,
                        dropped: sanitized.dropped,
                        noun: "Snippet",
                        pluralNoun: "Snippets"
                    )
                }
            }
        }
    }
}

// MARK: - Entry row

private struct DictionaryEntryRow: View {
    let entry: DictionaryEntry
    let onTap: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
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

            DeleteRowButton(label: "Delete \(entry.canonicalForm.isEmpty ? "entry" : entry.canonicalForm)", action: onDelete)
        }
        .contextMenu {
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

/// BLOCKER 2, secondary: on macOS a `List` with no `selection:` binding gives
/// `ForEach.onDelete` no user-reachable affordance at all — there is no swipe
/// gesture and no `EditButton`, and these rows are `Button`s, which would
/// consume one anyway. The `onDelete` handler was therefore the *only* delete
/// path in a shipping build that could never fire, leaving Story 5.3/5.5's
/// "delete an entry" acceptance criterion unmet. This is the affordance that
/// meets it; `onDelete` is kept (and fixed) for keyboard-driven deletion and
/// for the day the list gains a selection binding.
private struct DeleteRowButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .help(label)
        .accessibilityLabel(label)
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
                        .disabled(!isTriggerUsable(newTrigger))
                }

                // MAJOR 3: a trigger is matched as a run of word tokens, so one
                // with no letters or digits in it at all can never match
                // anything. Saying so here is the difference between a trigger
                // that does nothing and a trigger the user believes works.
                if !newTrigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isTriggerUsable(newTrigger) {
                    Text("A trigger needs at least one letter or digit — punctuation on its own never matches.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("Each trigger is a spelling Whisper is known to produce for this term — an exact one, or one close enough to auto-correct. Triggers containing a geresh, apostrophe, full stop or space (מנכ״ל, node.js) are matched as the whole phrase.")
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

    private func isTriggerUsable(_ trigger: String) -> Bool {
        WordTokenizer.phrase(trigger, normalizing: HebrewNormalizer.normalize) != nil
    }

    private func addTrigger() {
        let trimmed = newTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isTriggerUsable(trimmed), !entry.triggers.contains(trimmed) else { return }
        entry.triggers.append(trimmed)
        newTrigger = ""
    }
}

// MARK: - Snippet row

private struct SnippetRow: View {
    let snippet: Snippet
    let onTap: () -> Void
    let onDelete: () -> Void

    private var bodyPreview: String {
        let firstLine = snippet.body.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return firstLine.isEmpty ? "Empty body" : firstLine
    }

    var body: some View {
        HStack {
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

            DeleteRowButton(label: "Delete \(snippet.cue.isEmpty ? "snippet" : snippet.cue)", action: onDelete)
        }
        .contextMenu {
            Button("Delete", role: .destructive, action: onDelete)
        }
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

                // BLOCKER 1: a Snippet with a blank body cannot be saved.
                // Its placeholder rehydrates to nothing, the pipeline's AD-2
                // blank guard then refuses the empty result, and the raw
                // `⟦S0⟧` is what gets injected and written to History.
                if snippet.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("A Snippet needs a body — an empty one has nothing to expand into.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

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
                .disabled(
                    SnippetStore.collisionKey(for: snippet.cue) == nil
                        || snippet.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
    }
}
