// PostProcessSettingsTab.swift
// VocaMac
//
// Configure and verify the local LLM that cleans transcripts.
// One file per tab, following the StatsSettingsTab precedent.

import SwiftUI

struct PostProcessSettingsTab: View {
    @EnvironmentObject var appState: AppState

    @State private var connectionState: ConnectionState = .idle
    @State private var showingRestorePromptConfirmation = false

    /// Held for the tab's lifetime rather than built fresh per click, so
    /// repeated "Test Connection" clicks reuse one URLSession's connection
    /// pool instead of leaking a new one each time (MINOR 13).
    private let postProcessService = PostProcessService()

    /// NFR-1 expects only loopback traffic; the endpoint is user-configurable
    /// per the AC, so this is a warning rather than a hard block (MINOR 12).
    private var isEndpointLoopback: Bool {
        guard let host = URL(string: appState.postProcessBaseURL)?.host?.lowercased() else {
            return true
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    enum ConnectionState: Equatable {
        case idle
        case testing
        case succeeded(model: String)
        case failed(reason: String)
    }

    var body: some View {
        Form {
            Section("Post-Processing") {
                Toggle("Clean transcripts with a local LLM", isOn: $appState.postProcessEnabled)

                Text("Removes filler words, adds punctuation, resolves self-corrections, and formats spoken lists. If the model is slow or unreachable, your raw transcript is used instead — dictation never waits and never fails because of this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Backend") {
                // A TextField nested inside LabeledContent renders its own
                // title as trailing text on macOS; the field carries the label.
                // The placeholder shown when empty is the value actually in
                // effect, not a generic label — a cleared field falls back to
                // it silently otherwise (MINOR 15).
                TextField(PostProcessSettings.Default.baseURL, text: $appState.postProcessBaseURL)
                    .textFieldStyle(.roundedBorder)

                if !isEndpointLoopback {
                    Label("This endpoint is not on localhost — VocaMac will send transcripts to it over the network.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                TextField(PostProcessSettings.Default.model, text: $appState.postProcessModel)
                    .textFieldStyle(.roundedBorder)

                LabeledContent("Timeout") {
                    HStack {
                        Slider(value: $appState.postProcessTimeout, in: 1...15, step: 0.5)
                            .frame(maxWidth: 200)
                        Text(String(format: "%.1fs", appState.postProcessTimeout))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Temperature") {
                    HStack {
                        Slider(value: $appState.postProcessTemperature, in: 0...1, step: 0.1)
                            .frame(maxWidth: 200)
                        Text(String(format: "%.1f", appState.postProcessTemperature))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 12) {
                    Button("Test Connection") {
                        testConnection()
                    }
                    .controlSize(.small)
                    .disabled(connectionState == .testing)

                    connectionStatus
                }
            }

            Section("System Prompt") {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $appState.postProcessSystemPrompt)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 140)
                        .border(Color.secondary.opacity(0.3))

                    // TextEditor has no built-in placeholder; an emptied
                    // prompt silently falls back to the shipped default
                    // (PostProcessSettings.current()), so say so rather than
                    // showing nothing (MINOR 15).
                    if appState.postProcessSystemPrompt.isEmpty {
                        Text("Empty — the built-in default prompt is used.")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }

                HStack {
                    Text("The examples at the bottom of the prompt do most of the work. Removing them degrades self-correction handling noticeably.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Restore Default") {
                        showingRestorePromptConfirmation = true
                    }
                    .controlSize(.small)
                    .disabled(appState.postProcessSystemPrompt == Prompts.cleanTranscriptSystemPrompt)
                }
            }
        }
        .formStyle(.grouped)
        .alert("Restore the default system prompt?", isPresented: $showingRestorePromptConfirmation) {
            Button("Restore", role: .destructive) {
                appState.postProcessSystemPrompt = Prompts.cleanTranscriptSystemPrompt
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your edits to the prompt will be replaced by the prompt VocaMac ships with.")
        }
    }

    // MARK: - Connection status

    @ViewBuilder
    private var connectionStatus: some View {
        switch connectionState {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…").font(.caption).foregroundStyle(.secondary)
            }
        case .succeeded(let model):
            Label("Connected — \(model)", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .help(reason)
        }
    }

    /// Runs off the main actor's critical path and always resolves, so the UI
    /// can never be left stuck on "Testing…".
    private func testConnection() {
        connectionState = .testing
        let configuration = PostProcessConfiguration(
            baseURL: appState.postProcessBaseURL,
            model: appState.postProcessModel,
            timeout: appState.postProcessTimeout,
            temperature: appState.postProcessTemperature
        )

        Task { @MainActor in
            switch await postProcessService.testConnection(configuration: configuration) {
            case .success(let model):
                connectionState = .succeeded(model: model)
            case .failure(let error):
                connectionState = .failed(reason: error.reason)
            }
        }
    }
}
