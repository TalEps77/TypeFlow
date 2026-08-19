// CommandModeCoordinator.swift
// VocaMac
//
// The second route (AD-4). Command Mode reads the user's selection, sends it
// to the LLM alongside the spoken instruction, and writes the rewrite back
// over the selection.
//
// It does **not** use `TranscriptPipeline`, and it inverts AD-2's identity
// fallback. Dictation's rule is "on failure, keep the raw transcript" —
// always safe, because the worst case is unpolished text. Command Mode's
// worst case is different in kind: falling back to the raw transcript would
// paste the spoken *instruction* ("תקצר את זה למשפט אחד") over the paragraph
// the user selected, destroying it. So on any failure at all — no selection,
// an unreadable element, an unreachable LLM, a timeout, an answer that fails
// validation, an unwritable target — this changes nothing and says so.
//
// AD-5 runs through the whole type: the selected text is context. It lives in
// `snapshot` for the length of one operation, is never logged (only its
// length is), never persisted, and there is no field on `HistoryRecord`
// capable of holding it or the rewrite derived from it.

import Foundation

/// Everything a completed Command Mode operation reports back. Deliberately
/// carries no text: the rewrite is derived from the user's document, and
/// nothing downstream — history, logging, UI — has any business holding it
/// once it has been written into their app (AD-5).
struct CommandOutcome: Equatable {
    let targetBundleIdentifier: String?
    let selectionCharacters: Int
    let rewrittenCharacters: Int
    let postProcessMillis: Double
}

/// Why a Command Mode operation aborted. Every case means "nothing was
/// changed"; the associated values exist so the user can be told which wall
/// they hit, not so anything can be retried automatically.
enum CommandModeError: Error, Equatable {
    case noSelection(SelectionError)
    case emptyInstruction
    case llm(PostProcessError)
    case write(SelectionError)
    /// The selection was released while this operation was suspended — a
    /// force recovery, an audio device change, a newer gesture. The write is
    /// abandoned rather than completed, because "recover" has to mean the
    /// operation really is over.
    case abandoned

    /// One short sentence, safe to show and safe to log: it names the failure,
    /// never the selection, the instruction, or the rewrite.
    var userMessage: String {
        switch self {
        case .noSelection(let error):
            switch error {
            case .noSelection:
                return "Command Mode: select some text first — nothing was changed."
            case .notTrusted:
                return "Command Mode needs Accessibility permission — nothing was changed."
            default:
                return "Command Mode could not read the selection (\(error.reason)) — nothing was changed."
            }
        case .emptyInstruction:
            return "Command Mode heard no instruction — nothing was changed."
        case .llm(let error):
            return "Command Mode could not rewrite the selection (\(error.reason)) — nothing was changed."
        case .write(let error):
            return "Command Mode could not replace the selection (\(error.reason)) — nothing was changed."
        case .abandoned:
            return "Command Mode was cancelled — nothing was changed."
        }
    }
}

@MainActor
final class CommandModeCoordinator {

    private let textInjector: TextInjecting
    private let postProcessService: PostProcessing

    /// The selection captured when the gesture began. Held for exactly one
    /// operation and dropped on every path out (AD-5).
    private var snapshot: SelectionSnapshot?

    init(textInjector: TextInjecting, postProcessService: PostProcessing) {
        self.textInjector = textInjector
        self.postProcessService = postProcessService
    }

    var hasSelection: Bool { snapshot != nil }

    /// The number of characters currently held, for tests and logging. Never
    /// the characters themselves.
    var selectionCharacterCount: Int { snapshot?.text.count ?? 0 }

    /// Read the selection at the moment the gesture begins — before any audio
    /// is recorded.
    ///
    /// Reading now rather than at stop time is the same reasoning as AD-5's
    /// "capture at recording start": what the user had selected when they
    /// pressed the key is what they meant to rewrite, and a selection read
    /// several seconds later may have been changed by the act of speaking
    /// (a Push-to-Talk key that also moves the caret, an app that deselects
    /// on focus change). It also means a Command Mode gesture with nothing
    /// selected costs the user nothing: it aborts before the microphone is
    /// ever opened.
    @discardableResult
    func captureSelection() -> Result<Void, CommandModeError> {
        switch textInjector.readSelectionResult() {
        case .success(let captured):
            snapshot = captured
            VocaLogger.info(.commandMode, "Captured a \(captured.text.count)-character selection in \(captured.bundleIdentifier ?? "an unknown app")")
            return .success(())
        case .failure(let error):
            snapshot = nil
            return .failure(.noSelection(error))
        }
    }

    /// Release the selection without doing anything with it. Called on every
    /// abandoned path — a failed audio start, a device change, a force
    /// recovery — so document text is never left resident (AD-5).
    func discardSelection() {
        guard snapshot != nil else { return }
        snapshot = nil
        VocaLogger.debug(.commandMode, "Discarded the captured selection")
    }

    /// Send the selection and the spoken instruction to the LLM and, only if
    /// the answer passes Command Mode's own validation, write it back over the
    /// selection.
    ///
    /// The selection is released before this returns, on every path.
    func rewrite(
        instruction: String,
        systemPrompt: String,
        configuration: PostProcessConfiguration
    ) async -> Result<CommandOutcome, CommandModeError> {
        guard let snapshot else {
            return .failure(.noSelection(.noSelection))
        }
        // Whatever happens below, this operation owns the selection and no
        // later one may inherit it.
        defer { discardSelection() }

        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstruction.isEmpty else {
            return .failure(.emptyInstruction)
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        let rewritten: String
        switch await postProcessService.command(
            selection: snapshot.text,
            instruction: trimmedInstruction,
            systemPrompt: systemPrompt,
            configuration: configuration
        ) {
        case .success(let text):
            rewritten = text
        case .failure(let error):
            return .failure(.llm(error))
        }
        let postProcessMillis = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000

        // The LLM round trip above is the long suspension in this flow, and
        // `discardSelection()` may have been called during it — a force
        // recovery, an audio device change, the user starting a new gesture.
        // The local `snapshot` captured before the await survives that, so
        // without this check an abandoned operation would still write into the
        // user's document seconds after they told the app to give up.
        guard self.snapshot != nil else {
            VocaLogger.warning(.commandMode, "The selection was released while the LLM was working — abandoning the rewrite")
            return .failure(.abandoned)
        }

        // The write proves for itself that focus and the selected text are
        // still what was captured; if they are not, it refuses and we abort
        // rather than writing into whatever the user moved to.
        if case .failure(let error) = textInjector.replaceSelection(rewritten, replacing: snapshot) {
            return .failure(.write(error))
        }

        return .success(CommandOutcome(
            targetBundleIdentifier: snapshot.bundleIdentifier,
            selectionCharacters: snapshot.text.count,
            rewrittenCharacters: rewritten.count,
            postProcessMillis: postProcessMillis
        ))
    }
}
