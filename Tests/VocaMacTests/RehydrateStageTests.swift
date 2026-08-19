// RehydrateStageTests.swift
// VocaMac Tests
//
// Story 5.4: RehydrateStage's own validation (missing/altered placeholder
// rejects the whole post-processing result and falls back to the pre-LLM
// text), plus end-to-end coverage of the AD-3 stage order — Snippet bodies
// surviving a real PostProcess round trip, and Snippets working with no LLM
// at all.

import XCTest
@testable import VocaMac

@MainActor
final class RehydrateStageTests: XCTestCase {

    // MARK: - No snippets to rehydrate

    func testDeclinesWhenThereAreNoProtectedSpans() async {
        let stage = RehydrateStage()

        let result = await stage.run(TranscriptContext(rawTranscript: "שלום עולם"))

        XCTAssertEqual(result.text, "שלום עולם")
        XCTAssertEqual(result.outcome, .skipped(reason: "no snippets to rehydrate"))
        XCTAssertFalse(result.didRun)
    }

    // MARK: - Every placeholder present: normal substitution

    func testSubstitutesEveryPlaceholderWhenAllArePresent() async {
        let stage = RehydrateStage()
        var context = TranscriptContext(rawTranscript: "raw")
        context.currentText = "Please add my ⟦S0⟧ here."
        context.protectedSpans = ["⟦S0⟧": "Best regards,\nJohn"]
        context.textBeforePostProcess = "please add my ⟦S0⟧ here"

        let result = await stage.run(context)

        XCTAssertEqual(result.text, "Please add my Best regards,\nJohn here.")
        XCTAssertEqual(result.outcome, .applied)
    }

    func testSubstitutesMultiplePlaceholders() async {
        let stage = RehydrateStage()
        var context = TranscriptContext(rawTranscript: "raw")
        context.currentText = "⟦S0⟧ and then ⟦S1⟧"
        context.protectedSpans = ["⟦S0⟧": "FIRST", "⟦S1⟧": "SECOND"]

        let result = await stage.run(context)

        XCTAssertEqual(result.text, "FIRST and then SECOND")
    }

    // MARK: - Dropped/altered placeholder: reject and fall back (AD-3 AC)

    func testFallsBackToPreLLMTextWhenAPlaceholderIsMissingEntirely() async {
        let stage = RehydrateStage()
        var context = TranscriptContext(rawTranscript: "raw")
        // The LLM rewrote the placeholder away entirely.
        context.currentText = "Please add your signature here."
        context.protectedSpans = ["⟦S0⟧": "Best regards,\nJohn"]
        context.textBeforePostProcess = "please add my ⟦S0⟧ here"

        let result = await stage.run(context)

        XCTAssertEqual(result.text, "please add my Best regards,\nJohn here",
                        "the pre-LLM snapshot is used, not a patch of the corrupted post-processed text")
        XCTAssertEqual(result.outcome, .applied)
        XCTAssertTrue(result.usedFallback,
                       "the whole post-processing result was discarded — History must be able to say so (MAJOR 4)")
    }

    func testDuplicatedPlaceholderIsRejectedRatherThanPastedTwice() async {
        // MINOR 5: presence alone is not enough. An LLM that repeats a
        // sentence leaves two copies of the same placeholder, and substituting
        // both pastes the whole signature block into the document twice.
        let stage = RehydrateStage()
        var context = TranscriptContext(rawTranscript: "raw")
        context.currentText = "Please add my ⟦S0⟧ here. Please add my ⟦S0⟧ here."
        context.protectedSpans = ["⟦S0⟧": "Best regards,\nJohn"]
        context.textBeforePostProcess = "please add my ⟦S0⟧ here"

        let result = await stage.run(context)

        XCTAssertEqual(result.text, "please add my Best regards,\nJohn here")
        XCTAssertTrue(result.usedFallback)
    }

    func testSubstitutionOrderIsDeterministicAcrossTenAndOne() async {
        // MINOR 4: `Dictionary` iteration order is unspecified, so a body that
        // contains something shaped like another placeholder used to expand or
        // not depending on hash order. Descending index order fixes that and
        // also keeps ⟦S1⟧ from being confused with a prefix of ⟦S10⟧.
        let stage = RehydrateStage()
        var spans: [String: String] = [:]
        var text = ""
        for index in 0...10 {
            spans["⟦S\(index)⟧"] = "BODY\(index)"
            text += "⟦S\(index)⟧ "
        }
        var context = TranscriptContext(rawTranscript: "raw")
        context.currentText = text
        context.protectedSpans = spans

        for _ in 0..<20 {
            let result = await stage.run(context)
            XCTAssertEqual(result.text, "BODY0 BODY1 BODY2 BODY3 BODY4 BODY5 BODY6 BODY7 BODY8 BODY9 BODY10 ")
        }
    }

    func testFallsBackWhenAPlaceholderIsAlteredRatherThanDropped() async {
        let stage = RehydrateStage()
        var context = TranscriptContext(rawTranscript: "raw")
        // The LLM "corrected" the brackets/casing -- no longer an exact match.
        context.currentText = "Please add my [S0] here."
        context.protectedSpans = ["⟦S0⟧": "Best regards,\nJohn"]
        context.textBeforePostProcess = "please add my ⟦S0⟧ here"

        let result = await stage.run(context)

        XCTAssertEqual(result.text, "please add my Best regards,\nJohn here")
    }

    func testWithNoFallbackSnapshotTheSnippetLossIsStillFlagged() async {
        // Defensive path: protectedSpans non-empty but textBeforePostProcess
        // was never set (should not happen in the real pipeline, since the
        // pipeline always snapshots it right after SnippetStage runs).
        //
        // MINOR 13: this used to assert plain `.applied` and so codified
        // silent snippet loss as success. The text is still adopted — there is
        // nothing better to adopt — but the run is flagged as a fallback, which
        // is what reaches History.
        let stage = RehydrateStage()
        var context = TranscriptContext(rawTranscript: "raw")
        context.currentText = "no placeholder survived here"
        context.protectedSpans = ["⟦S0⟧": "BODY"]
        context.textBeforePostProcess = nil

        let result = await stage.run(context)

        XCTAssertEqual(result.text, "no placeholder survived here")
        XCTAssertEqual(result.outcome, .applied)
        XCTAssertTrue(result.usedFallback)
    }

    // MARK: - End-to-end: Snippet -> PostProcess -> Rehydrate (AD-3)

    func testSnippetBodySurvivesARealPostProcessRoundTrip() async {
        let snippets = [Snippet(cue: "signature", body: "Best regards,\nJohn")]
        let postProcessService = MockPostProcessService()
        postProcessService.cleanResult = .success("Please add my ⟦S0⟧ here.")

        let pipeline = TranscriptPipeline(stages: [
            SnippetStage(snippetsProvider: { snippets }),
            PostProcessStage(service: postProcessService, settingsProvider: { PostProcessSettings(isEnabled: true) }),
            RehydrateStage()
        ])

        let result = await pipeline.run(TranscriptContext(rawTranscript: "please add my signature here"))

        XCTAssertEqual(result.currentText, "Please add my Best regards,\nJohn here.")
        XCTAssertEqual(postProcessService.lastText, "please add my ⟦S0⟧ here",
                        "PostProcess must only ever see the placeholder, never the real body")
    }

    func testCorruptedPlaceholderRejectsTheWholeCleanupResult() async {
        let snippets = [Snippet(cue: "signature", body: "Best regards,\nJohn")]
        let postProcessService = MockPostProcessService()
        // The LLM "translated" the cue instead of leaving the placeholder alone.
        postProcessService.cleanResult = .success("Please add your signature here.")

        let pipeline = TranscriptPipeline(stages: [
            SnippetStage(snippetsProvider: { snippets }),
            PostProcessStage(service: postProcessService, settingsProvider: { PostProcessSettings(isEnabled: true) }),
            RehydrateStage()
        ])

        let result = await pipeline.run(TranscriptContext(rawTranscript: "please add my signature here"))

        XCTAssertEqual(result.currentText, "please add my Best regards,\nJohn here")
        XCTAssertTrue(result.didFallback, "the discarded cleanup must reach HistoryRecord.didFallback (MAJOR 4)")
    }

    // MARK: - Retention and the placeholder guard (MINOR 9, BLOCKER 1)

    func testProtectedSpansAndPreLLMSnapshotAreClearedBeforeTheContextIsReturned() async {
        let snippets = [Snippet(cue: "signature", body: "Best regards,\nJohn")]
        let pipeline = TranscriptPipeline(stages: [
            SnippetStage(snippetsProvider: { snippets }, settingsProvider: { SnippetSettings(isEnabled: true) }),
            RehydrateStage()
        ])

        let result = await pipeline.run(TranscriptContext(rawTranscript: "please add my signature here"))

        XCTAssertEqual(result.currentText, "please add my Best regards,\nJohn here")
        XCTAssertTrue(result.protectedSpans.isEmpty, "snippet bodies must not outlive the run that used them")
        XCTAssertNil(result.textBeforePostProcess)
    }

    func testASnippetWithABlankBodyNeverMintsAPlaceholder() async {
        // BLOCKER 1: dictating exactly the Cue of an empty-bodied Snippet used
        // to inject the literal "⟦S0⟧" — the placeholder rehydrated to nothing,
        // the runner's AD-2 blank guard refused the empty result, and the
        // pre-rehydration text was what got injected and recorded.
        let snippets = [Snippet(cue: "signature", body: "   ")]
        let pipeline = TranscriptPipeline(stages: [
            SnippetStage(snippetsProvider: { snippets }, settingsProvider: { SnippetSettings(isEnabled: true) }),
            RehydrateStage()
        ])

        let result = await pipeline.run(TranscriptContext(rawTranscript: "signature"))

        XCTAssertEqual(result.currentText, "signature")
        XCTAssertFalse(SnippetService.containsPlaceholder(result.currentText))
    }

    func testAPlaceholderThatSomehowSurvivesFallsBackToTheRawTranscript() async {
        // The runner's last line of defence: a stage list that protects but
        // never rehydrates must still not put machinery in the user's document.
        let snippets = [Snippet(cue: "signature", body: "Best regards,\nJohn")]
        let pipeline = TranscriptPipeline(stages: [
            SnippetStage(snippetsProvider: { snippets }, settingsProvider: { SnippetSettings(isEnabled: true) })
        ])

        let result = await pipeline.run(TranscriptContext(rawTranscript: "please add my signature here"))

        XCTAssertEqual(result.currentText, "please add my signature here")
        XCTAssertTrue(result.didFallback)
    }

    func testSnippetsExpandWithPostProcessingDisabled() async {
        // Snippets do not require the LLM (Story 5.4 AC).
        let snippets = [Snippet(cue: "signature", body: "Best regards,\nJohn")]
        let postProcessService = MockPostProcessService()
        postProcessService.cleanResult = .success("THIS MUST NEVER BE CALLED")

        let pipeline = TranscriptPipeline(stages: [
            SnippetStage(snippetsProvider: { snippets }),
            PostProcessStage(service: postProcessService, settingsProvider: { PostProcessSettings(isEnabled: false) }),
            RehydrateStage()
        ])

        let result = await pipeline.run(TranscriptContext(rawTranscript: "please add my signature here"))

        XCTAssertEqual(postProcessService.cleanCallCount, 0)
        XCTAssertEqual(result.currentText, "please add my Best regards,\nJohn here")
    }

    func testStageOrderIsDictionaryThenSnippetThenPostProcessThenRehydrate() async {
        // Force PostProcess off regardless of ambient UserDefaults state —
        // this test only cares about stage order and Dictionary/Snippet
        // results, not the real (networked) PostProcessService (MINOR 8,
        // same precaution as PostProcessStageTests).
        let defaults = VocaDefaults.store
        let previousValue = defaults.object(forKey: PostProcessSettings.Key.enabled)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: PostProcessSettings.Key.enabled)
            } else {
                defaults.removeObject(forKey: PostProcessSettings.Key.enabled)
            }
        }
        defaults.set(false, forKey: PostProcessSettings.Key.enabled)

        let dictionaryStore = DictionaryStore(store: JSONFileStore(
            fileName: "dictionary.json",
            defaultValue: [DictionaryEntry(canonicalForm: "Kubernetes", triggers: ["קוברנטיס"])],
            directoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("vocamac_test_dictionary_\(UUID().uuidString)", isDirectory: true)
        ))
        let snippetStore = SnippetStore(store: JSONFileStore(
            fileName: "snippets.json",
            defaultValue: [Snippet(cue: "signature", body: "SIG")],
            directoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("vocamac_test_snippets_\(UUID().uuidString)", isDirectory: true)
        ))
        let pipeline = TranscriptPipeline.production(dictionaryStore: dictionaryStore, snippetStore: snippetStore)

        let result = await pipeline.run(TranscriptContext(rawTranscript: "קוברנטיס signature"))

        XCTAssertEqual(result.reports.map(\.stageName), ["Dictionary", "Snippet", "PostProcess", "Rehydrate"])
        XCTAssertEqual(result.currentText, "Kubernetes SIG")
    }
}
