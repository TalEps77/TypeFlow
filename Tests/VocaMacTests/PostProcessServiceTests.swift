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

    func testRequestTargetsOnlyTheConfiguredLoopbackHost() throws {
        // NFR-1: the app must keep working with no internet route, which it can
        // only do if nothing here reaches past the configured endpoint.
        let url = try XCTUnwrap(PostProcessRequestBuilder.chatCompletionsURL(baseURL: "http://localhost:1234"))
        XCTAssertEqual(url.host, "localhost")
        XCTAssertEqual(url.port, 1234)
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
        let input = "אני צריך להזמין פגישה למחר"
        let englishAnswer = "Sure, I can help you schedule that meeting for tomorrow"

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
