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

    /// Cancels a scheduled re-read that has not fired yet, releasing the
    /// injected text it was holding on to. Called by `AppState` on every
    /// abort path alongside the Cursor Context discard (BLOCKER 1), and at the
    /// start of every new recording (MAJOR 8): a dictation the user abandoned
    /// — or superseded — must not reach back into their focused text field a
    /// second later, and its text should not outlive it.
    func cancelPendingObservation()
}

@MainActor
final class CorrectionLearner: CorrectionLearning {

    var onCandidateProposed: ((CorrectionCandidate) -> Void)?

    private let contextReader: ContextReading
    private let dismissedStore: DismissedCorrectionsStore
    private let isEnabledProvider: () -> Bool
    private let scheduleReRead: (DispatchWorkItem) -> Void

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
        scheduleReRead: ((DispatchWorkItem) -> Void)? = nil
    ) {
        self.contextReader = contextReader
        self.dismissedStore = dismissedStore
        self.isEnabledProvider = isEnabledProvider
        self.scheduleReRead = scheduleReRead ?? { workItem in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    /// The one re-read waiting to happen, if any.
    ///
    /// A `DispatchWorkItem` rather than a bare closure (MAJOR 8) so cancelling
    /// really cancels: an `asyncAfter` closure cannot be withdrawn once
    /// enqueued, so the only thing a flag could do was make the timer fire and
    /// then decline — and a second dictation started 200ms after the first left
    /// two live timers racing to read the same field.
    private var pendingWorkItem: DispatchWorkItem?

    /// The injected text the pending re-read will diff against, held here
    /// rather than captured in the work item so `cancelPendingObservation` can
    /// actually release it, not merely skip the diff.
    private var pendingObservation: (text: String, processIdentifier: pid_t?)?

    func observeInjection(_ text: String, targetProcessIdentifier: pid_t?) {
        guard isEnabledProvider() else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // A newer injection supersedes an older one: the field the previous
        // re-read was going to look at is not where the user is any more.
        cancelPendingObservation()

        pendingObservation = (text: text, processIdentifier: targetProcessIdentifier)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.pendingObservation else { return }
            self.pendingObservation = nil
            self.pendingWorkItem = nil
            self.performReReadAndDiff(
                injectedText: pending.text,
                targetProcessIdentifier: pending.processIdentifier
            )
        }
        pendingWorkItem = workItem
        scheduleReRead(workItem)
    }

    func cancelPendingObservation() {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        pendingObservation = nil
    }

    private func performReReadAndDiff(injectedText: String, targetProcessIdentifier: pid_t?) {
        // Re-checked at fire time, not only at schedule time (MAJOR 8): the
        // toggle can be switched off inside the delay, and a feature the user
        // has just turned off must not perform one last read of their screen.
        guard isEnabledProvider() else { return }

        // BLOCKER 3: no target process, no read. `AXContextReader` refuses a
        // `nil` process identifier outright — there is no system-wide fallback
        // behind it any more — but stating it here means the guarantee does not
        // rest on the behavior of whichever `ContextReading` is injected.
        guard let targetProcessIdentifier else { return }

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
