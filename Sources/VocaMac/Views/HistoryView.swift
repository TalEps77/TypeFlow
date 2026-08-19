// HistoryView.swift
// VocaMac
//
// Browse, search, and manage dictation history (FR-11). Shows the Raw
// Transcript alongside the Final Text so the LLM's edit (if any) is
// inspectable, per Story 3.2.

import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchQuery: String = ""
    @State private var selectedRecordID: UUID?
    @State private var showingDeleteAllConfirmation = false

    private var filteredRecords: [HistoryRecord] {
        appState.historyStore.search(searchQuery)
    }

    var body: some View {
        NavigationSplitView {
            Group {
                if filteredRecords.isEmpty {
                    emptyState
                } else {
                    List(filteredRecords, selection: $selectedRecordID) { record in
                        HistoryRowView(record: record)
                            .tag(record.id)
                            .contextMenu {
                                Button("Re-paste") {
                                    appState.rePaste(record)
                                }
                                Button("Delete", role: .destructive) {
                                    delete(record)
                                }
                            }
                    }
                }
            }
            .searchable(text: $searchQuery, prompt: "Search history")
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        retentionMenu
                        Divider()
                        Button("Delete All…", role: .destructive) {
                            showingDeleteAllConfirmation = true
                        }
                        .disabled(appState.historyStore.records.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        } detail: {
            if let record = appState.historyStore.records.first(where: { $0.id == selectedRecordID }) {
                HistoryDetailView(
                    record: record,
                    onRePaste: { appState.rePaste(record) },
                    onDelete: { delete(record) }
                )
            } else {
                Text("Select a dictation to view its details")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 680, minHeight: 440)
        .alert("Delete All History?", isPresented: $showingDeleteAllConfirmation) {
            Button("Delete All", role: .destructive) {
                appState.historyStore.deleteAll()
                selectedRecordID = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all dictation history. This action cannot be undone.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(searchQuery.isEmpty ? "No dictations yet" : "No matches for \"\(searchQuery)\"")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var retentionMenu: some View {
        Menu("Keep last \(retentionLabel)") {
            Button("Unlimited") { appState.historyStore.retentionLimit = 0 }
            ForEach([50, 100, 250, 500, 1000], id: \.self) { count in
                Button("\(count) records") { appState.historyStore.retentionLimit = count }
            }
        }
    }

    private var retentionLabel: String {
        appState.historyStore.retentionLimit == 0 ? "∞" : "\(appState.historyStore.retentionLimit)"
    }

    private func delete(_ record: HistoryRecord) {
        if selectedRecordID == record.id {
            selectedRecordID = nil
        }
        appState.historyStore.delete(record.id)
    }
}

// MARK: - Row

struct HistoryRowView: View {
    let record: HistoryRecord

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Self.dateFormatter.string(from: record.timestamp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if record.didFallback {
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("Post-processing fell back to the raw transcript")
                }
                Text(record.targetBundleId ?? "Unknown app")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(record.preview.isEmpty ? "(empty)" : record.preview)
                .font(.body)
                .lineLimit(2)
            Text("\(record.modelName) • ASR \(HistoryDetailView.millisecondsLabel(record.asrMillis))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

struct HistoryDetailView: View {
    let record: HistoryRecord
    let onRePaste: () -> Void
    let onDelete: () -> Void

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        InfoRow2(label: "When", value: Self.dateFormatter.string(from: record.timestamp))
                        InfoRow2(label: "App", value: record.targetBundleId ?? "Unknown")
                        InfoRow2(label: "Model", value: record.modelName)
                        InfoRow2(label: "Mode", value: record.mode == .command ? "Command" : "Dictation")
                        InfoRow2(label: "Recording", value: Self.millisecondsLabel(record.recordingMillis))
                        InfoRow2(label: "ASR", value: Self.millisecondsLabel(record.asrMillis))
                        if record.postProcessMillis > 0 {
                            InfoRow2(label: "Post-process", value: Self.millisecondsLabel(record.postProcessMillis))
                        }
                        if record.didFallback {
                            InfoRow2(label: "Fallback", value: "Post-processing failed — raw transcript used")
                        }
                    }
                    .padding(6)
                }

                // A Command Mode record holds the spoken *instruction* in both
                // text fields — the selection and the rewrite are document
                // content and are never persisted (AD-5) — so "injected" and
                // "transcript" would both be lies about it (MINOR 3).
                if record.mode == .command {
                    textSection(title: "Instruction (spoken)", text: record.finalText)
                } else if record.finalText != record.rawTranscript {
                    textSection(title: "Final Text (injected)", text: record.finalText)
                    textSection(title: "Raw Transcript", text: record.rawTranscript)
                } else {
                    textSection(title: "Transcript", text: record.finalText)
                }

                HStack {
                    Button(action: onRePaste) {
                        Label("Re-paste", systemImage: "arrow.uturn.forward.circle")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)

                    Button(role: .destructive, action: onDelete) {
                        Label("Delete This Record", systemImage: "trash")
                    }
                    .controlSize(.small)
                }
            }
            .padding()
        }
    }

    fileprivate static func millisecondsLabel(_ millis: Double) -> String {
        millis >= 1000 ? String(format: "%.1fs", millis / 1000) : String(format: "%.0fms", millis)
    }

    private func textSection(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(text.isEmpty ? "(empty)" : text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
        }
    }
}
