// PostProcessServiceTests.swift
// VocaMac Tests
//
// Prompt construction and response validation are pure by design (NFR-6), so
// everything that decides whether a transcript is accepted is tested here with
// no network at all. The transport-level guarantees (deadline, connection
// refused) are exercised against a real socket.

import XCTest
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

    private func payload(content: String) -> Data {
        Data(#"{"model":"m","choices":[{"message":{"role":"assistant","content":"\#(content)"}}]}"#.utf8)
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

        // lower bound = 200 * 0.5 - 40 = 60 ; upper bound = 200 * 2.0 + 40 = 440
        XCTAssertTrue(PostProcessResponseValidator.isProportionate(input: input, output: String(repeating: "b", count: 60)))
        XCTAssertFalse(PostProcessResponseValidator.isProportionate(input: input, output: String(repeating: "b", count: 59)))
        XCTAssertTrue(PostProcessResponseValidator.isProportionate(input: input, output: String(repeating: "b", count: 440)))
        XCTAssertFalse(PostProcessResponseValidator.isProportionate(input: input, output: String(repeating: "b", count: 441)))
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

    func testDeadlineIsHonoredWhenNothingEverAnswers() async {
        let service = PostProcessService()
        // 203.0.113.0/24 is TEST-NET-3: routable-looking, never answers, so the
        // connection hangs rather than being refused.
        let configuration = PostProcessConfiguration(baseURL: "http://203.0.113.1:1234", timeout: 1.0)

        let startedAt = Date()
        let result = await service.clean(text: "שלום עולם", systemPrompt: "s", configuration: configuration)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(result.failureError, .timedOut(1.0))
        XCTAssertLessThan(elapsed, 2.0, "the outer Task deadline must cut the wait close to the timeout")
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
