// PostProcessServiceTests.swift
// VocaMac Tests
//
// Prompt construction and response validation are pure by design (NFR-6), so
// everything that decides whether a transcript is accepted is tested here with
// no network at all. The transport-level guarantees (deadline, connection
// refused) are exercised against a real socket.

import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import VocaMac

final class PostProcessRequestBuilderTests: XCTestCase {

    // MARK: - Endpoint resolution

    func testPlainBaseURLGetsTheChatCompletionsPath() {
        let url = PostProcessRequestBuilder.chatCompletionsURL(baseURL: "http://localhost:1234")
        XCTAssertEqual(url?.absoluteString, "http://localhost:1234/v1/chat/completions")
    }

    func testTrailingSlashIsTolerated() {
        let url = PostProcessRequestBuilder.chatCompletionsURL(baseURL: "http://localhost:1234/")
        XCTAssertEqual(url?.absoluteString, "http://localhost:1234/v1/chat/completions")
    }

    func testBaseURLThatAlreadyEndsInV1IsNotDoubled() {
        let url = PostProcessRequestBuilder.chatCompletionsURL(baseURL: "http://localhost:1234/v1")
        XCTAssertEqual(url?.absoluteString, "http://localhost:1234/v1/chat/completions")

        let withSlash = PostProcessRequestBuilder.chatCompletionsURL(baseURL: "http://localhost:1234/v1/")
        XCTAssertEqual(withSlash?.absoluteString, "http://localhost:1234/v1/chat/completions")
    }

    func testSurroundingWhitespaceIsTrimmed() {
        let url = PostProcessRequestBuilder.chatCompletionsURL(baseURL: "  http://127.0.0.1:1234  ")
        XCTAssertEqual(url?.absoluteString, "http://127.0.0.1:1234/v1/chat/completions")
    }

    func testUnusableBaseURLsAreRejected() {
        XCTAssertNil(PostProcessRequestBuilder.chatCompletionsURL(baseURL: ""))
        XCTAssertNil(PostProcessRequestBuilder.chatCompletionsURL(baseURL: "   "))
        XCTAssertNil(PostProcessRequestBuilder.chatCompletionsURL(baseURL: "localhost:1234"), "no scheme")
        XCTAssertNil(PostProcessRequestBuilder.chatCompletionsURL(baseURL: "http://"), "no host")
    }

    func testModelsURLSharesTheSameResolution() {
        XCTAssertEqual(
            PostProcessRequestBuilder.modelsURL(baseURL: "http://localhost:1234/v1/")?.absoluteString,
            "http://localhost:1234/v1/models"
        )
    }

    // MARK: - Body

    func testBodyCarriesSystemPromptThenWrappedTranscript() {
        let configuration = PostProcessConfiguration(model: "test-model", temperature: 0.2)
        let body = PostProcessRequestBuilder.body(
            text: "נפגש מחר",
            systemPrompt: "SYSTEM",
            configuration: configuration
        )

        XCTAssertEqual(body.model, "test-model")
        XCTAssertEqual(body.temperature, 0.2)
        XCTAssertFalse(body.stream, "streaming would break the single-response contract")
        XCTAssertEqual(body.messages.count, 2)
        XCTAssertEqual(body.messages[0].role, "system")
        XCTAssertEqual(body.messages[0].content, "SYSTEM")
        XCTAssertEqual(body.messages[1].role, "user")
        XCTAssertEqual(body.messages[1].content, "Transcript: נפגש מחר\nCleaned:")
    }

    // MARK: - Cursor Context (Story 4.4)

    func testNoContextLeavesTheRequestByteForByteUnchanged() {
        let withoutContext = PostProcessRequestBuilder.body(
            text: "נפגש מחר",
            systemPrompt: "SYSTEM",
            configuration: PostProcessConfiguration()
        )
        let withExplicitNilContext = PostProcessRequestBuilder.body(
            text: "נפגש מחר",
            systemPrompt: "SYSTEM",
            contextBefore: nil,
            contextAfter: nil,
            configuration: PostProcessConfiguration()
        )

        XCTAssertEqual(withoutContext, withExplicitNilContext)
        XCTAssertEqual(withoutContext.messages[0].content, "SYSTEM", "no addendum without context")
        XCTAssertEqual(withoutContext.messages[1].content, "Transcript: נפגש מחר\nCleaned:")
    }

    func testContextBeforeAndAfterAppearInTheUserMessage() {
        let body = PostProcessRequestBuilder.body(
            text: "נפגש מחר",
            systemPrompt: "SYSTEM",
            contextBefore: "some prior text",
            contextAfter: "some following text",
            configuration: PostProcessConfiguration()
        )

        XCTAssertTrue(body.messages[1].content.contains("some prior text"))
        XCTAssertTrue(body.messages[1].content.contains("some following text"))
        XCTAssertTrue(body.messages[1].content.contains("Transcript: נפגש מחר"))
    }

    func testContextAppendsInstructionsToTheSystemPromptOnlyWhenPresent() {
        let body = PostProcessRequestBuilder.body(
            text: "נפגש מחר",
            systemPrompt: "SYSTEM",
            contextBefore: "before",
            contextAfter: nil,
            configuration: PostProcessConfiguration()
        )

        XCTAssertTrue(body.messages[0].content.hasPrefix("SYSTEM"))
        XCTAssertGreaterThan(body.messages[0].content.count, "SYSTEM".count, "the Cursor Context addendum must be appended")
    }

    func testEmptyStringContextIsTreatedTheSameAsNoContext() {
        let body = PostProcessRequestBuilder.body(
            text: "נפגש מחר",
            systemPrompt: "SYSTEM",
            contextBefore: "",
            contextAfter: "",
            configuration: PostProcessConfiguration()
        )

        XCTAssertEqual(body.messages[0].content, "SYSTEM")
        XCTAssertEqual(body.messages[1].content, "Transcript: נפגש מחר\nCleaned:")
    }

    // MARK: - max_tokens (BLOCKER 1)

    func testMaxTokensIsSetExplicitlyRatherThanLeftToTheServer() {
        let configuration = PostProcessConfiguration()
        let shortText = "שלום"
        let body = PostProcessRequestBuilder.body(text: shortText, systemPrompt: "s", configuration: configuration)

        XCTAssertEqual(body.maxTokens, PostProcessRequestBuilder.maxTokens(forInputCharacterCount: shortText.count))
        XCTAssertEqual(body.maxTokens, 256, "a floor applies for very short input so a brief cleanup is never starved")
    }

    func testMaxTokensScalesWithInputForLongerTranscripts() {
        let longText = String(repeating: "מילה ", count: 200) // 1000 characters
        let body = PostProcessRequestBuilder.body(text: longText, systemPrompt: "s", configuration: PostProcessConfiguration())

        XCTAssertEqual(body.maxTokens, longText.count * 2)
        XCTAssertGreaterThan(body.maxTokens, 256, "the floor must not clip a long, legitimate transcript")
    }

    func testUserMessageMatchesTheFewShotFormat() {
        // The examples in the system prompt use exactly this shape; the model
        // starts answering the transcript when the shapes drift apart.
        XCTAssertEqual(Prompts.cleanTranscriptUserMessage(for: "שלום"), "Transcript: שלום\nCleaned:")
        XCTAssertTrue(Prompts.cleanTranscriptSystemPrompt.contains("Transcript: "))
        XCTAssertTrue(Prompts.cleanTranscriptSystemPrompt.contains("Cleaned: "))
    }

    func testURLRequestIsAPostOfJSONUnderTheTimeout() throws {
        let url = try XCTUnwrap(PostProcessRequestBuilder.chatCompletionsURL(baseURL: "http://localhost:1234"))
        let body = PostProcessRequestBuilder.body(text: "x", systemPrompt: "s", configuration: PostProcessConfiguration())
        let request = try PostProcessRequestBuilder.urlRequest(url: url, body: body, timeout: 3.5)

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 3.5)
        XCTAssertNotNil(request.httpBody)
    }

    // MARK: - Loopback predicate (Story 9.2)

    func testLoopbackHostsAreAccepted() {
        for host in ["localhost", "LocalHost", "127.0.0.1", "127.0.0.2", "127.255.255.254", "::1", "[::1]"] {
            XCTAssertTrue(PostProcessRequestBuilder.isLoopback(host: host), "\(host) is loopback")
        }
    }

    func testNonLoopbackHostsAreRejected() {
        // `127.example.com` and `1270.0.0.1` are the cases a string match on
        // "127." would wave through; `128.0.0.1` is the /8 boundary.
        for host in [
            "192.168.1.10",
            "evil.example.com",
            "127.example.com",
            "1270.0.0.1",
            "128.0.0.1",
            "126.255.255.255",
            "localhost.evil.com",
            "127.0.0",
            "",
            // `URL.host` percent-decodes, so `localhost%20` arrives here as
            // "localhost " while the wire authority keeps the escape. The
            // predicate matches verbatim rather than trimming (MINOR-5).
            "localhost ",
            " 127.0.0.1"
        ] {
            XCTAssertFalse(PostProcessRequestBuilder.isLoopback(host: host), "\(host) is not loopback")
        }
    }

    func testLoopbackCheckReadsTheHostOfAResolvedEndpoint() throws {
        let loopback = try XCTUnwrap(PostProcessRequestBuilder.chatCompletionsURL(baseURL: "http://localhost:1234"))
        XCTAssertTrue(PostProcessRequestBuilder.isLoopback(url: loopback))

        let remote = try XCTUnwrap(PostProcessRequestBuilder.chatCompletionsURL(baseURL: "http://evil.example.com"))
        XCTAssertFalse(PostProcessRequestBuilder.isLoopback(url: remote))
    }
}

final class PostProcessResponseValidatorTests: XCTestCase {

    /// Built with JSONSerialization rather than string interpolation
    /// (MINOR 14) — a `content` containing a quote, backslash, or newline
    /// used to produce invalid JSON that decoded as something other than
    /// what the test intended, silently.
    private func payload(content: String, finishReason: String? = "stop") -> Data {
        let message: [String: Any] = ["role": "assistant", "content": content]
        var choice: [String: Any] = ["message": message]
        if let finishReason {
            choice["finish_reason"] = finishReason
        }
        let object: [String: Any] = [
            "model": "m",
            "choices": [choice]
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - Happy path

    func testValidResponseYieldsTrimmedContent() {
        let result = PostProcessResponseValidator.validate(
            data: payload(content: "  נפגש בשלוש.  "),
            statusCode: 200,
            input: "נפגש בשתיים בעצם בשלוש"
        )
        XCTAssertEqual(try? result.get(), "נפגש בשלוש.")
    }

    // MARK: - Rejections

    func testNonSuccessStatusIsRejected() {
        for code in [400, 404, 429, 500, 503] {
            let result = PostProcessResponseValidator.validate(data: payload(content: "x"), statusCode: code, input: "input")
            XCTAssertEqual(result.failureError, .httpStatus(code))
        }
    }

    func testMalformedJSONIsRejected() {
        let result = PostProcessResponseValidator.validate(data: Data("not json".utf8), statusCode: 200, input: "input")
        XCTAssertEqual(result.failureError, .malformedResponse("could not decode chat completion"))
    }

    func testMissingChoicesIsRejected() {
        let result = PostProcessResponseValidator.validate(data: Data(#"{"model":"m","choices":[]}"#.utf8), statusCode: 200, input: "input")
        XCTAssertEqual(result.failureError, .malformedResponse("no choices in response"))

        let absent = PostProcessResponseValidator.validate(data: Data(#"{"model":"m"}"#.utf8), statusCode: 200, input: "input")
        XCTAssertEqual(absent.failureError, .malformedResponse("no choices in response"))
    }

    func testMissingContentIsRejected() {
        let result = PostProcessResponseValidator.validate(data: Data(#"{"choices":[{"message":{}}]}"#.utf8), statusCode: 200, input: "input")
        XCTAssertEqual(result.failureError, .malformedResponse("no message content in first choice"))
    }

    func testEmptyOrWhitespaceContentIsRejected() {
        XCTAssertEqual(PostProcessResponseValidator.validate(data: payload(content: ""), statusCode: 200, input: "input").failureError, .emptyContent)
        XCTAssertEqual(PostProcessResponseValidator.validate(data: payload(content: "   "), statusCode: 200, input: "input").failureError, .emptyContent)
    }

    func testRunawayOutputIsRejected() {
        // The failure this guard exists for: an early prompt made the model
        // answer "כתוב לי שיר על חתולים" with an actual poem.
        let poem = String(repeating: "שורה בשיר ", count: 60)
        let input = "כתוב לי שיר על חתולים"
        let result = PostProcessResponseValidator.validate(data: payload(content: poem), statusCode: 200, input: input)

        guard case .disproportionateLength = result.failureError else {
            return XCTFail("A 600-character answer to a 21-character transcript must be rejected")
        }
    }

    // MARK: - Length-ratio boundaries

    func testLengthRatioBoundaries() {
        let input = String(repeating: "a", count: 200)   // long enough that the short-input allowance does not dominate

        // lower bound = 200 * 0.5 - 40 = 60
        // upper bound = max(200 * 2.0, 200 + 25) = 400 — the ratio dominates at this length (MAJOR 3)
        XCTAssertTrue(PostProcessResponseValidator.isProportionate(input: input, output: String(repeating: "b", count: 60)))
        XCTAssertFalse(PostProcessResponseValidator.isProportionate(input: input, output: String(repeating: "b", count: 59)))
        XCTAssertTrue(PostProcessResponseValidator.isProportionate(input: input, output: String(repeating: "b", count: 400)))
        XCTAssertFalse(PostProcessResponseValidator.isProportionate(input: input, output: String(repeating: "b", count: 401)))
    }

    func testUpperBoundStaysTightForShortInputs() {
        // MAJOR 3: the old formula added the same 40-character
        // shortInputAllowance to BOTH bounds, so an 18-char input accepted
        // anything up to 76 characters — comfortably wide enough for the
        // model to answer instead of clean. The fixed upper bound is
        // `max(input * 2, input + 25)`, with no lower-bound-style slack.
        for inputCount in [10, 20, 40] {
            let input = String(repeating: "a", count: inputCount)
            let upperBound = max(inputCount * 2, inputCount + 25)

            XCTAssertTrue(
                PostProcessResponseValidator.isProportionate(input: input, output: String(repeating: "b", count: upperBound)),
                "\(inputCount)-char input should accept exactly \(upperBound) characters"
            )
            XCTAssertFalse(
                PostProcessResponseValidator.isProportionate(input: input, output: String(repeating: "b", count: upperBound + 1)),
                "\(inputCount)-char input should reject \(upperBound + 1) characters"
            )
        }
    }

    func testShortInputsGetSlack() {
        // "נפגש בשתיים בעצם בשלוש" (22) -> "נפגש בשלוש." (11) must pass even
        // though it is half the length: correction resolution is meant to cut.
        XCTAssertTrue(PostProcessResponseValidator.isProportionate(input: "נפגש בשתיים בעצם בשלוש", output: "נפגש בשלוש."))
        // A short transcript turned into a bulleted list must also pass.
        XCTAssertTrue(PostProcessResponseValidator.isProportionate(
            input: "צריך לקנות חלב לחם ביצים גבינה ועגבניות",
            output: "צריך לקנות:\n- חלב\n- לחם\n- ביצים\n- גבינה\n- עגבניות"
        ))
    }

    func testEmptyInputIsNeverProportionate() {
        XCTAssertFalse(PostProcessResponseValidator.isProportionate(input: "", output: "anything"))
    }

    // MARK: - finish_reason (BLOCKER 1)

    func testFinishReasonOtherThanStopIsRejected() {
        // The exact failure mode this exists for: the backend's own
        // max_tokens cut the completion off mid-sentence, and the truncated
        // text would otherwise be indistinguishable from a complete one.
        let result = PostProcessResponseValidator.validate(
            data: payload(content: "נפגש בשלוש", finishReason: "length"),
            statusCode: 200,
            input: "נפגש בשתיים בעצם בשלוש"
        )
        guard case .malformedResponse(let detail) = result.failureError else {
            return XCTFail("a response cut off at the token cap must be rejected regardless of its length")
        }
        XCTAssertTrue(detail.contains("length"), "the reason should say why it was rejected: \(detail)")
    }

    func testStopFinishReasonIsAccepted() {
        let result = PostProcessResponseValidator.validate(
            data: payload(content: "נפגש בשלוש.", finishReason: "stop"),
            statusCode: 200,
            input: "נפגש בשתיים בעצם בשלוש"
        )
        XCTAssertEqual(try? result.get(), "נפגש בשלוש.")
    }

    func testMissingFinishReasonIsAccepted() {
        // Not every OpenAI-compatible backend necessarily sends the field;
        // treat its absence as unremarkable rather than as a rejection.
        let result = PostProcessResponseValidator.validate(
            data: payload(content: "נפגש בשלוש.", finishReason: nil),
            statusCode: 200,
            input: "נפגש בשתיים בעצם בשלוש"
        )
        XCTAssertEqual(try? result.get(), "נפגש בשלוש.")
    }

    // MARK: - Similarity to input (MAJOR 4)

    func testBigramSimilarityOfIdenticalStringsIsOne() {
        XCTAssertEqual(PostProcessResponseValidator.bigramSimilarity("שלום עולם", "שלום עולם"), 1.0)
    }

    func testBigramSimilarityOfDisjointScriptsIsZero() {
        XCTAssertEqual(PostProcessResponseValidator.bigramSimilarity("שלום עולם", "hello world"), 0.0)
    }

    func testLegitimateCleanupsClearTheSimilarityBar() {
        // The same corpus as testShortInputsGetSlack (MAJOR 3) — these must
        // pass the length band AND the similarity bar, not just one of them.
        XCTAssertTrue(PostProcessResponseValidator.isRelated(
            input: "נפגש בשתיים בעצם בשלוש",
            output: "נפגש בשלוש."
        ))
        XCTAssertTrue(PostProcessResponseValidator.isRelated(
            input: "צריך לקנות חלב לחם ביצים גבינה ועגבניות",
            output: "צריך לקנות:\n- חלב\n- לחם\n- ביצים\n- גבינה\n- עגבניות"
        ))
    }

    func testFewShotEchoIsRejectedEvenWithinTheLengthBand() {
        // The model answers with an unrelated example line lifted from its
        // own system prompt. Roughly the same length as the input, so the
        // length guard alone lets it through — only content similarity
        // catches this.
        let input = "תזכיר לי לקנות ביצים"
        let echoed = "נפגש ביום רביעי בבוקר"
        XCTAssertTrue(PostProcessResponseValidator.isProportionate(input: input, output: echoed),
                      "the echo must land inside the length band, or this test proves nothing")

        let result = PostProcessResponseValidator.validate(data: payload(content: echoed), statusCode: 200, input: input)
        XCTAssertEqual(result.failureError, .malformedResponse("output unrelated to input"))
    }

    func testLanguageFlipIsRejected() {
        // Same shape as the echo test above: the answer must land inside the
        // length band itself, or the length guard rejects it first and this
        // test would no longer be exercising language-flip detection at all.
        let input = "אני צריך להזמין פגישה למחר"
        let englishAnswer = "Sure, I'll book that meeting tomorrow."
        XCTAssertTrue(PostProcessResponseValidator.isProportionate(input: input, output: englishAnswer),
                      "the answer must land inside the length band, or this test proves nothing")

        let result = PostProcessResponseValidator.validate(data: payload(content: englishAnswer), statusCode: 200, input: input)
        XCTAssertEqual(result.failureError, .malformedResponse("output unrelated to input"))
    }

    func testShortAnswerInsteadOfCleanupIsRejectedByLengthOrSimilarity() {
        // MAJOR 3 + MAJOR 4 together: at a short input length the old upper
        // bound (input*2 + shortInputAllowance) let a plausible-length
        // *answer* through; the new upper bound still has some fixed slack
        // (input + 25), so a 34-character reply to a 16-character transcript
        // still lands in band — it is the similarity check that catches it.
        let input = "תזכיר לי דבר אחד"
        let answer = "בטח, אני אזכיר לך את זה בקרוב מאוד"
        XCTAssertTrue(PostProcessResponseValidator.isProportionate(input: input, output: answer),
                      "this case is exactly the one the length guard alone cannot catch")
        XCTAssertFalse(PostProcessResponseValidator.isRelated(input: input, output: answer))

        let result = PostProcessResponseValidator.validate(data: payload(content: answer), statusCode: 200, input: input)
        XCTAssertEqual(result.failureError, .malformedResponse("output unrelated to input"))
    }

    // MARK: - Cursor Context echo (MAJOR 4, AD-5)

    /// A document sentence long enough to build precise-length windows out of.
    private static let documentText =
        "the quarterly board pack is confidential and must not be shared outside the finance team"

    func testCursorContextEchoDetection() {
        struct Case {
            let name: String
            let output: String
            let contextBefore: String?
            let contextAfter: String?
            let isEcho: Bool
        }

        let document = Self.documentText
        let window40 = String(document.prefix(40))
        let window39 = String(document.prefix(39))
        let hebrewDocument = "הישיבה הסודית על רכישת חברת הלברד נדחתה לחודש הבא בגלל בעיות רגולציה"

        let cases: [Case] = [
            Case(
                name: "no context sent — the check must not fire at all",
                output: document,
                contextBefore: nil,
                contextAfter: nil,
                isEcho: false
            ),
            Case(
                name: "context present but empty",
                output: document,
                contextBefore: "",
                contextAfter: "",
                isEcho: false
            ),
            Case(
                name: "output shorter than one window cannot contain one",
                output: "short answer",
                contextBefore: document,
                contextAfter: nil,
                isEcho: false
            ),
            Case(
                name: "one character under the threshold is allowed through",
                output: "cleaned words " + window39,
                contextBefore: document,
                contextAfter: nil,
                isEcho: false
            ),
            Case(
                name: "exactly the threshold is rejected",
                output: "cleaned words " + window40,
                contextBefore: document,
                contextAfter: nil,
                isEcho: true
            ),
            Case(
                name: "an echo of the text after the caret counts too",
                output: "cleaned words " + window40,
                contextBefore: nil,
                contextAfter: document,
                isEcho: true
            ),
            Case(
                name: "re-casing and re-wrapping what it copied does not hide it",
                output: "CLEANED  WORDS\n" + window40.uppercased().replacingOccurrences(of: " ", with: "   "),
                contextBefore: document,
                contextAfter: nil,
                isEcho: true
            ),
            Case(
                name: "Hebrew is not a special case",
                output: "שלום עולם " + String(hebrewDocument.prefix(45)),
                contextBefore: hebrewDocument,
                contextAfter: nil,
                isEcho: true
            ),
            Case(
                name: "an ordinary cleanup that merely sits in the same document",
                output: "So the quarterly figures came in under what we forecast.",
                contextBefore: document,
                contextAfter: nil,
                isEcho: false
            )
        ]

        for testCase in cases {
            let echo = PostProcessResponseValidator.cursorContextEcho(
                output: testCase.output,
                contextBefore: testCase.contextBefore,
                contextAfter: testCase.contextAfter
            )
            XCTAssertEqual(echo != nil, testCase.isEcho, testCase.name)
        }
    }

    /// The worked example from the review, reproduced exactly: this is the
    /// shape that both existing guards wave through.
    ///
    /// A 102-character transcript answered with 98 characters of genuine
    /// cleanup plus 80 characters lifted verbatim from the document is 179
    /// characters — inside the length band, whose upper bound here is 204 —
    /// and scores ~0.68 on bigram similarity because most of it really *is*
    /// the transcript, comfortably over the 0.5 bar. Before this guard those
    /// 80 characters of a confidential document were typed into the user's
    /// app and written to history.json as `finalText`.
    func testPartiallyEchoedContextPassesBothOldGuardsAndIsRejectedByTheNewOne() {
        let transcript = "um so the quarterly figures came in a bit under what we forecast and uh we should revisit the plan now"
        let cleaned = "So the quarterly figures came in a bit under what we forecast, and we should revisit the plan now."
        let contextBefore = "Board briefing, strictly confidential. Project Marigold remains unannounced and the acquisition of Halberd Systems closes on the 14th of next month."
        let echoed = String(contextBefore.dropFirst(38).prefix(80))
        let laundered = cleaned + " " + echoed

        // The premise: both guards that existed before genuinely pass this.
        XCTAssertEqual(transcript.count, 102)
        XCTAssertEqual(echoed.count, 80)
        XCTAssertEqual(laundered.count, 179)
        XCTAssertTrue(
            PostProcessResponseValidator.isProportionate(input: transcript, output: laundered),
            "if the length guard rejected this, the test would prove nothing about the new one"
        )
        XCTAssertTrue(
            PostProcessResponseValidator.isRelated(input: transcript, output: laundered),
            "if the similarity guard rejected this, the test would prove nothing about the new one"
        )

        // Without the context it is still accepted — the hole was never in
        // the response, it was in validating the response without reference
        // to what was sent alongside the request.
        XCTAssertEqual(
            try? PostProcessResponseValidator.validate(
                data: payload(content: laundered),
                statusCode: 200,
                input: transcript
            ).get(),
            laundered
        )

        // With it, rejected — and AD-2 hands the raw transcript back instead.
        let guarded = PostProcessResponseValidator.validate(
            data: payload(content: laundered),
            statusCode: 200,
            input: transcript,
            contextBefore: contextBefore,
            contextAfter: nil
        )
        XCTAssertEqual(guarded.failureError, .echoedCursorContext(sharedCharacters: 40))
    }

    /// The other half of the same story: cleanup done *with* context, that
    /// does not copy from it, must still be accepted. A guard that rejected
    /// this would quietly turn Story 4.4 off for everyone who enabled it.
    func testAnHonestCleanupWithContextStillPasses() {
        let transcript = "um so the quarterly figures came in a bit under what we forecast and uh we should revisit the plan now"
        let cleaned = "So the quarterly figures came in a bit under what we forecast, and we should revisit the plan now."
        let contextBefore = "Board briefing, strictly confidential. Project Marigold remains unannounced and the acquisition of Halberd Systems closes on the 14th of next month."

        let result = PostProcessResponseValidator.validate(
            data: payload(content: cleaned),
            statusCode: 200,
            input: transcript,
            contextBefore: contextBefore,
            contextAfter: "The finance team will circulate the revised deck on Friday."
        )

        XCTAssertEqual(try? result.get(), cleaned)
    }

    /// The rejection's `reason` is written into the log by `_clean`. It must
    /// say how much was copied and never what was copied (AD-5).
    func testTheRejectionReasonNamesNoDocumentText() {
        let reason = PostProcessError.echoedCursorContext(sharedCharacters: 40).reason

        XCTAssertTrue(reason.contains("40"))
        XCTAssertFalse(reason.contains(Self.documentText))
    }
}

@MainActor
final class PostProcessServiceTransportTests: XCTestCase {

    func testEmptyInputIsRejectedBeforeAnyRequest() async {
        let service = PostProcessService()
        // Port 1 is not listening; reaching the network at all would surface as
        // a transport error instead of .emptyInput.
        let configuration = PostProcessConfiguration(baseURL: "http://127.0.0.1:1", timeout: 5)

        let result = await service.clean(text: "   \n ", systemPrompt: "s", configuration: configuration)

        XCTAssertEqual(result.failureError, .emptyInput)
    }

    func testInvalidEndpointIsRejectedBeforeAnyRequest() async {
        let service = PostProcessService()
        let configuration = PostProcessConfiguration(baseURL: "not a url")

        let result = await service.clean(text: "שלום", systemPrompt: "s", configuration: configuration)

        XCTAssertEqual(result.failureError, .invalidEndpoint("not a url"))
    }

    func testUnreachableBackendFailsFastAndReportsTheReason() async {
        let service = PostProcessService()
        let configuration = PostProcessConfiguration(baseURL: "http://127.0.0.1:1", timeout: 5)

        let startedAt = Date()
        let result = await service.clean(text: "שלום עולם", systemPrompt: "s", configuration: configuration)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertNotNil(result.failureError, "a refused connection must not look like success")
        XCTAssertLessThan(elapsed, 5.0, "connection refused should surface immediately, not at the deadline")
    }

    func testDeadlineIsHonoredWhenNothingEverAnswers() async throws {
        // A local socket that accepts the TCP connection at the kernel level
        // (so `connect()` succeeds) but never calls `accept()`/`read()`/
        // `write()` — nothing ever arrives back. This is what a dribbling
        // backend looks like at the transport layer (MINOR 11), and unlike a
        // real unreachable host (203.0.113.1, TEST-NET-3) it cannot produce
        // a `.transport(...)` error instead of `.timedOut` depending on how
        // the test machine's network is set up (MAJOR 6).
        let listener = try XCTUnwrap(NeverRespondingListener(), "could not bind a local test listener")
        let service = PostProcessService()
        let configuration = PostProcessConfiguration(baseURL: "http://127.0.0.1:\(listener.port)", timeout: 1.0)

        let startedAt = Date()
        let result = await service.clean(text: "שלום עולם", systemPrompt: "s", configuration: configuration)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(result.failureError, .timedOut(1.0))
        XCTAssertLessThan(elapsed, 2.0, "the outer Task deadline must cut the wait close to the timeout")
    }

    // MARK: - Loopback enforcement at the service boundary (Story 9.2)

    /// Every accepted host must actually reach the transport — otherwise the
    /// reject assertions below would pass for a service that never sends
    /// anything at all. All three entry points are driven, so inverting any one
    /// of the three guards fails the suite (MEDIUM-3).
    func testLoopbackEndpointsReachTheTransport() async {
        for host in ["localhost", "127.0.0.1", "127.0.0.2", "[::1]"] {
            RecordingURLProtocol.reset()
            let service = PostProcessService(session: RecordingURLProtocol.session())
            let configuration = PostProcessConfiguration(baseURL: "http://\(host):1234", timeout: 5)

            _ = await service.clean(text: "שלום עולם", systemPrompt: "s", configuration: configuration)
            XCTAssertEqual(RecordingURLProtocol.requestCount, 1, "clean should have contacted \(host)")

            _ = await service.command(selection: "שלום עולם", instruction: "תקן", configuration: configuration)
            XCTAssertEqual(RecordingURLProtocol.requestCount, 2, "command should have contacted \(host)")

            _ = await service.testConnection(configuration: configuration)
            XCTAssertEqual(RecordingURLProtocol.requestCount, 3, "testConnection should have contacted \(host)")
        }
    }

    /// AC 9.2-2/3: a non-loopback endpoint is refused before a request is
    /// built, so nothing whatsoever reaches URLSession.
    func testNonLoopbackEndpointsNeverReachTheTransport() async {
        for host in ["192.168.1.10", "evil.example.com"] {
            let baseURL = "http://\(host):1234"

            RecordingURLProtocol.reset()
            let service = PostProcessService(session: RecordingURLProtocol.session())
            let configuration = PostProcessConfiguration(baseURL: baseURL, timeout: 5)

            let cleaned = await service.clean(text: "שלום עולם", systemPrompt: "s", configuration: configuration)
            let commanded = await service.command(selection: "שלום", instruction: "תקן", configuration: configuration)
            let tested = await service.testConnection(configuration: configuration)

            XCTAssertEqual(cleaned.failureError, .invalidEndpoint(baseURL), "clean must refuse \(host)")
            XCTAssertEqual(commanded.failureError, .invalidEndpoint(baseURL), "command must refuse \(host)")
            XCTAssertEqual(tested.failureError, .invalidEndpoint(baseURL), "testConnection must refuse \(host)")
            XCTAssertEqual(RecordingURLProtocol.requestCount, 0, "nothing may leave for \(host)")
        }
    }

    // MARK: - Redirects (Story 9.2, MAJOR-1)

    /// The loopback guard runs once, on the configured endpoint. A malicious or
    /// compromised process owning that local port could answer `307` and have
    /// URLSession re-POST the whole transcript to whatever `Location` names —
    /// the guard never sees the second host. Both listeners here are on
    /// loopback because a test cannot bind a public address, but "the redirect
    /// target is a different server that must receive nothing" is exactly the
    /// property under test; substitute a public host and this is exfiltration.
    func testARedirectFromTheConfiguredEndpointIsNeverFollowed() async throws {
        let completion = #"{"model":"m","choices":[{"message":{"role":"assistant","content":"שלום עולם."},"finish_reason":"stop"}]}"#
        // Answers a *valid* cleaned transcript, so a followed redirect would
        // make `clean` succeed — a loud, unmistakable failure of this test.
        let target = try XCTUnwrap(
            StubHTTPListener(
                response: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(completion.utf8.count)\r\nConnection: close\r\n\r\n" + completion
            ),
            "could not bind the redirect-target listener"
        )
        let redirector = try XCTUnwrap(
            StubHTTPListener(
                response: "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:\(target.port)/v1/chat/completions\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            ),
            "could not bind the redirecting listener"
        )

        let service = PostProcessService()
        let configuration = PostProcessConfiguration(baseURL: "http://127.0.0.1:\(redirector.port)", timeout: 5)

        let result = await service.clean(text: "שלום עולם", systemPrompt: "s", configuration: configuration)

        XCTAssertTrue(target.requests.isEmpty, "the transcript must never reach the redirect target")
        XCTAssertEqual(result.failureError, .httpStatus(307), "an unfollowed redirect is a failure, so the pipeline keeps the raw transcript")
        XCTAssertEqual(redirector.requests.count, 1, "sanity: the configured loopback endpoint was contacted")
        XCTAssertTrue(
            redirector.requests.first?.contains("שלום עולם") == true,
            "sanity: the body this test proves does not get forwarded was in fact sent to the configured endpoint"
        )
    }
}

// MARK: - Recording transport (Story 9.2)

/// Answers every request locally and counts the ones that actually reached
/// URLSession, so "the endpoint was contacted" and "nothing left the app" are
/// both directly assertable without opening a socket.
private final class RecordingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    static func reset() {
        lock.lock()
        count = 0
        lock.unlock()
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // `startLoading` runs exactly once per request that URLSession decided
        // to issue, which is what "a request left the service" means here.
        Self.lock.lock()
        Self.count += 1
        Self.lock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let body = Data(#"{"model":"m","choices":[{"message":{"role":"assistant","content":"שלום עולם."},"finish_reason":"stop"}]}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Local canned-response socket (Story 9.2, MAJOR-1)

/// A loopback TCP listener that answers every connection with one canned HTTP
/// response and records the raw bytes it was sent. Two of these reproduce the
/// redirect scenario end to end against the real production `URLSession`,
/// which a `URLProtocol` stub cannot do — URLSession's own redirect handling
/// is the thing under test.
private final class StubHTTPListener: @unchecked Sendable {

    /// Shared with the accept thread so the listener itself stays deallocatable
    /// (its `deinit` closes the socket, which is what ends that thread).
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []

        func append(_ entry: String) {
            lock.lock()
            entries.append(entry)
            lock.unlock()
        }

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }

    let port: UInt16
    private let fd: Int32
    private let log = Log()

    var requests: [String] { log.all }

    init?(response: String) {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return nil }

        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        addr.sin_port = 0 // ask the kernel for a free ephemeral port

        let bindResult = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(socketFD, 4) == 0 else {
            close(socketFD)
            return nil
        }

        var boundAddr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard nameResult == 0 else {
            close(socketFD)
            return nil
        }

        self.fd = socketFD
        self.port = UInt16(bigEndian: boundAddr.sin_port)

        let log = self.log
        Thread.detachNewThread {
            while true {
                let client = accept(socketFD, nil, nil)
                // `deinit` closes the listening socket, which is how this
                // thread is told to stop.
                guard client >= 0 else { return }

                // Headers and body arrive in separate segments, so read until
                // the peer goes quiet (the receive timeout below ends it) —
                // a single recv, or one that stops on a short read, would
                // capture the headers and miss the transcript.
                var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                // URLSession closes the connection as soon as it has decided
                // not to follow a redirect, which can happen before the write
                // below. Writing to a socket the peer already closed raises
                // SIGPIPE, whose default disposition kills the whole xctest
                // process (exit 141) rather than failing one test. This makes
                // the write return EPIPE instead.
                var noSIGPIPE: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))
                var received = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = recv(client, &buffer, buffer.count, 0)
                    guard count > 0 else { break }
                    received.append(contentsOf: buffer[0..<count])
                }
                log.append(String(decoding: received, as: UTF8.self))

                let bytes = Array(response.utf8)
                _ = bytes.withUnsafeBytes { raw in
                    Darwin.send(client, raw.baseAddress, raw.count, 0)
                }
                close(client)
            }
        }
    }

    deinit {
        close(fd)
    }
}

// MARK: - Local never-replying socket (MAJOR 6)

/// A TCP listener bound to an ephemeral loopback port that accepts
/// connections at the kernel level but never sends a byte back. Used to make
/// the deadline test above deterministic and independent of the test
/// machine's routing, instead of relying on a real host on the internet
/// silently dropping packets.
private final class NeverRespondingListener {
    let port: UInt16
    private let fd: Int32

    init?() {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return nil }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        addr.sin_port = 0 // ask the kernel for a free ephemeral port

        let bindResult = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(socketFD, 1) == 0 else {
            close(socketFD)
            return nil
        }

        var boundAddr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard nameResult == 0 else {
            close(socketFD)
            return nil
        }

        self.fd = socketFD
        self.port = UInt16(bigEndian: boundAddr.sin_port)
    }

    deinit {
        close(fd)
    }
}

// MARK: - Helper

extension Result where Failure == PostProcessError {
    /// The error, or nil on success. Keeps the assertions above to one line.
    var failureError: PostProcessError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
