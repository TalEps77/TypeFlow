// TranscriptContextScriptLanguageTests.swift
// VocaMac Tests
//
// Covers `TranscriptContext.scriptLanguage(of:)`, the script-based detector
// `PostProcessStage` uses to pick the cleanup prompt variant. It exists
// because `TranscriptContext.language` (requested-wins-over-detected) is
// wrong for this one decision: a user who selects English but dictates in
// Hebrew has Whisper correctly transcribe Hebrew, and the English cleanup
// prompt run on that text has the wrong self-correction markers and
// few-shot examples for it.

import XCTest
@testable import VocaMac

final class TranscriptContextScriptLanguageTests: XCTestCase {

    func testHebrewTextIsDetectedAsHebrew() {
        XCTAssertEqual(
            TranscriptContext.scriptLanguage(of: "שלום עולם מה נשמע היום"),
            "he"
        )
    }

    func testEnglishTextIsDetectedAsEnglish() {
        XCTAssertEqual(
            TranscriptContext.scriptLanguage(of: "hello world how are you today"),
            "en"
        )
    }

    /// The exact failure this detector fixes: the toggle says English, but
    /// the actual transcript — what PostProcessStage receives — is Hebrew.
    func testHebrewTextIsDetectedAsHebrewRegardlessOfTheRequestedLanguage() {
        let hebrewTranscript = "נפגש ביום שלישי אה לא ביום רביעי"
        XCTAssertEqual(TranscriptContext.scriptLanguage(of: hebrewTranscript), "he")
    }

    /// Majority-Hebrew mixed text: a couple of English words dropped into an
    /// otherwise Hebrew sentence should not flip the prompt to English.
    func testMixedTextWithMostlyHebrewIsDetectedAsHebrew() {
        XCTAssertEqual(
            TranscriptContext.scriptLanguage(of: "שלום אני רוצה לדבר על ה server החדש שלנו"),
            "he"
        )
    }

    /// Majority-English mixed text: one Hebrew word dropped into an English
    /// sentence should not flip the prompt to Hebrew.
    func testMixedTextWithMostlyEnglishIsDetectedAsEnglish() {
        XCTAssertEqual(
            TranscriptContext.scriptLanguage(of: "let's meet on Tuesday about the עדכון for the client"),
            "en"
        )
    }

    func testEmptyTextFallsBackToEnglish() {
        XCTAssertEqual(TranscriptContext.scriptLanguage(of: ""), "en")
    }

    func testWhitespaceOnlyTextFallsBackToEnglish() {
        XCTAssertEqual(TranscriptContext.scriptLanguage(of: "   \n\t "), "en")
    }

    func testNumbersOnlyTextFallsBackToEnglish() {
        XCTAssertEqual(TranscriptContext.scriptLanguage(of: "12345 67890 3.14"), "en")
    }

    func testNumbersAndPunctuationWithNoLettersFallsBackToEnglish() {
        XCTAssertEqual(TranscriptContext.scriptLanguage(of: "42, 100% - 7:30!"), "en")
    }
}
