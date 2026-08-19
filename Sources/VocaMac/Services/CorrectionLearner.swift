// CorrectionLearner.swift
// VocaMac
//
// Story 5.6: notices when the user hand-corrects an injected word, and
// proposes — never adds silently — a Dictionary Entry for it.
//
// Flow: after an injection, `observeInjection` schedules a re-read of the
// same focused element a short delay later. `CorrectionDiffing` (pure, no
// AX) decides whether the two texts differ by exactly one bounded,
// word-level edit. If so, and the pair was not already dismissed, the
// candidate is handed to `onCandidateProposed` — AppState is what actually
// surfaces it for confirmation and, on approval, adds it to the Dictionary.
//
// AD-5 still holds here even though this isn't Cursor Context: the re-read
// text itself never leaves this method, is never logged, and is never
// persisted. Only the two-word `CorrectionCandidate` extracted from it may
// be stored, and only after the user explicitly confirms (Story 5.6 AC).

import Foundation

@MainActor
protocol CorrectionLearning: AnyObject {
    var onCandidateProposed: ((CorrectionCandidate) -> Void)? { get set }

    /// Called once per injection. A no-op when correction learning is
    /// disabled (the common case, since it ships off) or when there is
    /// nothing to observe.
    func observeInjection(_ text: String, targetProcessIdentifier: pid_t?)

    /// Drops a scheduled re-read that has not fired yet, releasing the
    /// injected text it was holding on to. Called by `AppState` on every
    /// abort path alongside the Cursor Context discard (BLOCKER 1): a
    /// dictation the user abandoned must not reach back into their focused
    /// text field a second later, and its text should not outlive it.
    func cancelPendingObservation()
}

@MainActor
final class CorrectionLearner: CorrectionLearning {

    var onCandidateProposed: ((CorrectionCandidate) -> Void)?

    private let contextReader: ContextReading
    private let dismissedStore: DismissedCorrectionsStore
    private let isEnabledProvider: () -> Bool
    private let scheduleReRead: (@escaping () -> Void) -> Void

    /// - Parameters:
    ///   - delay: How long to wait before re-reading the field. Long enough
    ///     that the user has had a chance to notice and fix a mistake;
    ///     short enough that they are plausibly still in the same field.
    ///   - scheduleReRead: Overridable for tests, so a candidate can be
    ///     detected synchronously instead of waiting on a real timer.
    init(
        contextReader: ContextReading,
        dismissedStore: DismissedCorrectionsStore,
        isEnabledProvider: @escaping () -> Bool = { CorrectionLearningSettings.current().isEnabled },
        delay: TimeInterval = 1.5,
        scheduleReRead: ((@escaping () -> Void) -> Void)? = nil
    ) {
        self.contextReader = contextReader
        self.dismissedStore = dismissedStore
        self.isEnabledProvider = isEnabledProvider
        self.scheduleReRead = scheduleReRead ?? { action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    }

    /// The one re-read waiting to happen, if any. Held here rather than
    /// captured in the scheduled closure so `cancelPendingObservation` can
    /// actually release the injected text, not merely skip the diff.
    private var pendingObservation: (text: String, processIdentifier: pid_t?)?

    func observeInjection(_ text: String, targetProcessIdentifier: pid_t?) {
        guard isEnabledProvider() else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        pendingObservation = (text: text, processIdentifier: targetProcessIdentifier)
        scheduleReRead { [weak self] in
            guard let self, let pending = self.pendingObservation else { return }
            self.pendingObservation = nil
            self.performReReadAndDiff(
                injectedText: pending.text,
                targetProcessIdentifier: pending.processIdentifier
            )
        }
    }

    func cancelPendingObservation() {
        pendingObservation = nil
    }

    private func performReReadAndDiff(injectedText: String, targetProcessIdentifier: pid_t?) {
        guard let currentText = contextReader.readFocusedElementText(processIdentifier: targetProcessIdentifier) else {
            return
        }
        guard let candidate = CorrectionDiffing.detectCandidate(injected: injectedText, current: currentText) else {
            return
        }
        guard !dismissedStore.isDismissed(candidate) else { return }

        onCandidateProposed?(candidate)
    }
}
