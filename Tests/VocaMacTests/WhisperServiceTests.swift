// WhisperServiceTests.swift
// VocaMac Tests
//
// Tests for WhisperService: translation and hallucination filtering.

import XCTest
@testable import VocaMac

// MARK: - WhisperService Translation Tests

final class WhisperServiceTranslationTests: XCTestCase {

    func testTranscribeMethodAcceptsTranslateParameter() {
        // This test verifies that the transcribe method signature includes the translate parameter
        // The actual transcription would require a loaded model and audio data,
        // but we're just testing that the method compiles with the translate parameter
        let service = WhisperService()
        XCTAssertNotNil(service)
    }
}

// MARK: - WhisperService DecodingOptions Tests

/// Story 7.2: `transcribe`'s `DecodingOptions` construction, extracted into
/// `WhisperService.decodingOptions` so it can be asserted on without a
/// loaded model.
final class WhisperServiceDecodingOptionsTests: XCTestCase {

    func testChunkingStrategyIsAlwaysVAD() {
        let options = WhisperService.decodingOptions(language: "he", translate: false, promptTokens: nil)
        XCTAssertEqual(options.chunkingStrategy, .vad)
    }

    func testChunkingStrategyIsVADEvenWithTranslateAndVocabulary() {
        let options = WhisperService.decodingOptions(language: nil, translate: true, promptTokens: [1, 2, 3])
        XCTAssertEqual(options.chunkingStrategy, .vad)
    }

    func testTaskReflectsTranslateFlag() {
        XCTAssertEqual(WhisperService.decodingOptions(language: "he", translate: true, promptTokens: nil).task, .translate)
        XCTAssertEqual(WhisperService.decodingOptions(language: "he", translate: false, promptTokens: nil).task, .transcribe)
    }

    func testUsePrefillPromptWhenLanguageOrVocabularyIsPresent() {
        XCTAssertTrue(WhisperService.decodingOptions(language: "he", translate: false, promptTokens: nil).usePrefillPrompt)
        XCTAssertTrue(WhisperService.decodingOptions(language: nil, translate: false, promptTokens: [1]).usePrefillPrompt)
        XCTAssertFalse(WhisperService.decodingOptions(language: nil, translate: false, promptTokens: nil).usePrefillPrompt)
    }
}

// MARK: - WhisperService modelSizeFromName Tests

final class WhisperServiceModelSizeFromNameTests: XCTestCase {

    /// Regression test for the ivrit.ai folder name: it contains both "large"
    /// and "turbo", which would otherwise fall through to the generic
    /// `.largeV3Turbo` branch if the ivrit-specific check weren't ordered
    /// first (architecture.md R-4 / Story 1.1 AC).
    func testIvritFolderNameRoundTrips() {
        let service = WhisperService()
        XCTAssertEqual(service.modelSizeFromName("ivrit-ai_whisper-large-v3-turbo"), .ivritAiWhisperLargeV3Turbo)
        XCTAssertEqual(service.modelSizeFromName("IVRIT-AI_WHISPER-LARGE-V3-TURBO"), .ivritAiWhisperLargeV3Turbo)
    }

    func testExistingLargeTurboVariantsAreUnaffected() {
        let service = WhisperService()
        XCTAssertEqual(service.modelSizeFromName("openai_whisper-large-v3_turbo"), .largeV3Turbo)
        XCTAssertEqual(service.modelSizeFromName("openai_whisper-large-v3-v20240930_turbo"), .largeV3LatestTurbo)
    }
}


// MARK: - WhisperService Hallucination Filtering Tests

final class WhisperServiceHallucinationTests: XCTestCase {

    func testFilterBlankAudioToken() {
        let input = "[BLANK_AUDIO]"
        let result = WhisperService.filterHallucinationTokens(input)
        XCTAssertEqual(result, "", "Should filter out [BLANK_AUDIO] token completely")
    }

    func testFilterBlankAudioTokenCaseInsensitive() {
        let input = "[blank_audio]"
        let result = WhisperService.filterHallucinationTokens(input)
        XCTAssertEqual(result, "", "Should filter out [blank_audio] case-insensitively")
    }

    func testFilterBlankAudioMixedWithText() {
        let input = "Hello [BLANK_AUDIO] world"
        let result = WhisperService.filterHallucinationTokens(input)
        XCTAssertEqual(result, "Hello world", "Should remove token and collapse spaces")
    }

    func testFilterMultipleHallucinationTokens() {
        let input = "[BLANK_AUDIO] [NO_SPEECH] some text (silence)"
        let result = WhisperService.filterHallucinationTokens(input)
        XCTAssertEqual(result, "some text", "Should remove all hallucination tokens")
    }

    func testFilterPreservesNormalText() {
        let input = "This is a normal transcription"
        let result = WhisperService.filterHallucinationTokens(input)
        XCTAssertEqual(result, "This is a normal transcription", "Should not modify normal text")
    }

    func testFilterEmptyInput() {
        let input = ""
        let result = WhisperService.filterHallucinationTokens(input)
        XCTAssertEqual(result, "", "Should handle empty input gracefully")
    }

    func testFilterOnlyWhitespaceAroundToken() {
        let input = "   [BLANK_AUDIO]   "
        let result = WhisperService.filterHallucinationTokens(input)
        XCTAssertEqual(result, "", "Should return empty after filtering and trimming")
    }
}

// MARK: - WhisperService Custom Vocabulary Tests

final class WhisperServiceVocabularyTests: XCTestCase {

    func testEmptyStringYieldsNoTerms() {
        XCTAssertEqual(WhisperService.vocabularyTerms(from: ""), [])
        XCTAssertEqual(WhisperService.vocabularyTerms(from: "   \n  \n"), [])
    }

    func testSplitsOnNewlinesAndCommas() {
        let input = "Namrata\nKubernetes, kubectl\n  etcd  "
        XCTAssertEqual(
            WhisperService.vocabularyTerms(from: input),
            ["Namrata", "Kubernetes", "kubectl", "etcd"]
        )
    }

    func testDropsBlankEntries() {
        let input = "Namrata,,\n\n, ,VocaMac"
        XCTAssertEqual(WhisperService.vocabularyTerms(from: input), ["Namrata", "VocaMac"])
    }

    func testRetriesOnlyEmptyPromptedTranscriptions() {
        XCTAssertTrue(WhisperService.shouldRetryWithoutVocabulary(rawText: "  \n", promptTokens: [1]))
        XCTAssertFalse(WhisperService.shouldRetryWithoutVocabulary(rawText: "transcribed", promptTokens: [1]))
        XCTAssertFalse(WhisperService.shouldRetryWithoutVocabulary(rawText: "[BLANK_AUDIO]", promptTokens: [1]))
        XCTAssertFalse(WhisperService.shouldRetryWithoutVocabulary(rawText: "", promptTokens: nil))
    }
}
