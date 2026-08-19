// PostProcessService.swift
// VocaMac
//
// The only network boundary in the app (AD-6). Speaks OpenAI-compatible
// chat-completions to a local LLM backend (LM Studio by default) over
// loopback, under a hard deadline, and never lets a failure reach the user:
// every path that is not a validated cleaned transcript returns an error the
// caller turns back into the untouched input (AD-2).

import Foundation

// MARK: - Errors

enum PostProcessError: Error, Equatable {
    case emptyInput
    case invalidEndpoint(String)
    case timedOut(TimeInterval)
    case transport(String)
    case httpStatus(Int)
    case malformedResponse(String)
    case emptyContent
    case disproportionateLength(inputCharacters: Int, outputCharacters: Int)

    /// Short, actionable, and safe to show in the settings UI or write to a log.
    var reason: String {
        switch self {
        case .emptyInput:
            return "nothing to clean"
        case .invalidEndpoint(let value):
            return "invalid endpoint: \(value)"
        case .timedOut(let seconds):
            return String(format: "timed out after %.1fs", seconds)
        case .transport(let message):
            return "connection failed: \(message)"
        case .httpStatus(let code):
            return "server returned HTTP \(code)"
        case .malformedResponse(let detail):
            return "malformed response: \(detail)"
        case .emptyContent:
            return "model returned empty content"
        case .disproportionateLength(let input, let output):
            return "output length \(output) is disproportionate to input length \(input)"
        }
    }
}

// MARK: - Wire types

/// OpenAI-compatible chat-completions request.
struct ChatCompletionRequest: Encodable, Equatable {
    struct Message: Encodable, Equatable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    /// Our own explicit ceiling (BLOCKER 1). Without this the server's own
    /// default decides how many tokens a completion may run to, and a
    /// response cut off there is byte-for-byte indistinguishable from a
    /// complete one unless `finish_reason` is also checked.
    let maxTokens: Int
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
        case stream
    }
}

/// Only the fields we actually read.
struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }
        let message: Message?
        /// "stop" for a completion the model finished on its own; "length"
        /// when it was cut off at the token cap. Any other value is treated
        /// the same as "length" — the text cannot be trusted to be whole.
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    let model: String?
    let choices: [Choice]?
}

// MARK: - Pure request construction

/// Split out from the service so it is unit-testable with no network (NFR-6).
enum PostProcessRequestBuilder {

    /// Resolves the chat-completions URL from a user-typed base URL. Accepts
    /// "http://localhost:1234", a trailing slash, and a base that already ends
    /// in "/v1", all of which people type.
    static func chatCompletionsURL(baseURL: String) -> URL? {
        endpointURL(baseURL: baseURL, path: "chat/completions")
    }

    static func modelsURL(baseURL: String) -> URL? {
        endpointURL(baseURL: baseURL, path: "models")
    }

    static func endpointURL(baseURL: String, path: String) -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if trimmed.hasSuffix("/v1") {
            trimmed.removeLast(3)
        }
        guard let url = URL(string: trimmed + "/v1/" + path), url.scheme != nil, url.host != nil else {
            return nil
        }
        return url
    }

    static func body(
        text: String,
        systemPrompt: String,
        contextBefore: String? = nil,
        contextAfter: String? = nil,
        configuration: PostProcessConfiguration
    ) -> ChatCompletionRequest {
        // Story 4.4: the addendum only goes out when there is actually
        // context to use it on, so a request with none is identical to
        // every request before this story.
        let hasContext = (contextBefore?.isEmpty == false) || (contextAfter?.isEmpty == false)
        let effectiveSystemPrompt = hasContext ? systemPrompt + Prompts.cursorContextInstructions : systemPrompt

        return ChatCompletionRequest(
            model: configuration.model,
            messages: [
                .init(role: "system", content: effectiveSystemPrompt),
                .init(role: "user", content: Prompts.cleanTranscriptUserMessage(for: text, contextBefore: contextBefore, contextAfter: contextAfter))
            ],
            temperature: configuration.temperature,
            maxTokens: maxTokens(forInputCharacterCount: text.count),
            stream: false
        )
    }

    /// Sized generously above the input so a legitimate reformat (a spoken
    /// list turned into bullets can run longer than the transcript) is never
    /// clipped, but nowhere near "unbounded" — a runaway completion still
    /// hits our own cap long before it could hit the server's.
    static func maxTokens(forInputCharacterCount inputCharacterCount: Int) -> Int {
        max(256, inputCharacterCount * 2)
    }

    static func urlRequest(url: URL, body: ChatCompletionRequest, timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
}

// MARK: - Pure response validation

enum PostProcessResponseValidator {

    /// Cleaning removes fillers and adds punctuation; it never rewrites at
    /// length. Anything outside this band is the model having answered the
    /// transcript instead of cleaning it, and is rejected (AD-2).
    static let minimumLengthRatio = 0.5
    static let maximumLengthRatio = 2.0
    /// Slack on the LOWER bound only, for very short inputs where trimming a
    /// single filler word blows the shortening ratio. Shortening is the only
    /// direction that legitimately needs this — an upper-bound allowance
    /// this large would let a short *answer* through at the exact input
    /// lengths where the 4B model is most likely to answer instead of clean
    /// (MAJOR 3), which is what the shorter, fixed upper-bound slack below
    /// and the similarity check (MAJOR 4) are for instead.
    static let shortInputAllowance = 40
    /// Small, fixed upper-bound slack for short inputs (e.g. one word added
    /// for punctuation/context), independent of the ratio.
    static let shortInputUpperBoundAllowance = 25

    static func isProportionate(input: String, output: String) -> Bool {
        let inputCount = input.count
        let outputCount = output.count
        guard inputCount > 0 else { return false }

        let lowerBound = Double(inputCount) * minimumLengthRatio - Double(shortInputAllowance)
        let upperBound = max(
            Double(inputCount) * maximumLengthRatio,
            Double(inputCount) + Double(shortInputUpperBoundAllowance)
        )
        return Double(outputCount) >= lowerBound && Double(outputCount) <= upperBound
    }

    /// Below this normalized character-bigram overlap between input and
    /// output, the model answered the transcript instead of cleaning it —
    /// a language flip, an unrelated few-shot echo, or a leftover reasoning
    /// block all fail this even when they happen to land inside the length
    /// band (MAJOR 4).
    static let minimumSimilarity = 0.5

    /// Sørensen–Dice coefficient over character bigrams, treated as a
    /// multiset so a repeated bigram in one string can only match a repeated
    /// bigram in the other once. 1.0 for identical text, ~0.0 for text
    /// sharing no character pairs at all (e.g. different scripts).
    static func bigramSimilarity(_ a: String, _ b: String) -> Double {
        func bigrams(of text: String) -> [String] {
            let characters = Array(text)
            guard characters.count >= 2 else {
                return characters.isEmpty ? [] : [String(characters)]
            }
            return (0..<(characters.count - 1)).map { String(characters[$0...$0 + 1]) }
        }

        let bigramsA = bigrams(of: a)
        let bigramsB = bigrams(of: b)
        guard !bigramsA.isEmpty, !bigramsB.isEmpty else {
            return a == b ? 1.0 : 0.0
        }

        var remainingB = [String: Int]()
        for bigram in bigramsB {
            remainingB[bigram, default: 0] += 1
        }
        var matches = 0
        for bigram in bigramsA {
            if let count = remainingB[bigram], count > 0 {
                matches += 1
                remainingB[bigram] = count - 1
            }
        }
        return (2.0 * Double(matches)) / Double(bigramsA.count + bigramsB.count)
    }

    static func isRelated(input: String, output: String) -> Bool {
        bigramSimilarity(input, output) >= minimumSimilarity
    }

    /// Turns a raw HTTP answer into either cleaned text or the reason it was
    /// refused. Never returns text it has not checked.
    static func validate(data: Data, statusCode: Int, input: String) -> Result<String, PostProcessError> {
        guard (200...299).contains(statusCode) else {
            return .failure(.httpStatus(statusCode))
        }

        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            return .failure(.malformedResponse("could not decode chat completion"))
        }

        guard let choices = decoded.choices, !choices.isEmpty else {
            return .failure(.malformedResponse("no choices in response"))
        }
        guard let raw = choices[0].message?.content else {
            return .failure(.malformedResponse("no message content in first choice"))
        }
        // BLOCKER 1: a response cut off at the server's token cap is
        // otherwise indistinguishable from a complete one — the length guard
        // below only catches a truncation severe enough to fall out of band.
        if let finishReason = choices[0].finishReason, finishReason != "stop" {
            return .failure(.malformedResponse("model stopped early: \(finishReason)"))
        }

        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return .failure(.emptyContent)
        }
        guard isProportionate(input: input, output: cleaned) else {
            return .failure(.disproportionateLength(inputCharacters: input.count, outputCharacters: cleaned.count))
        }
        guard isRelated(input: input, output: cleaned) else {
            return .failure(.malformedResponse("output unrelated to input"))
        }

        return .success(cleaned)
    }
}

// MARK: - Protocol

/// Declared here rather than in ServiceProtocols.swift only because the
/// protocol's vocabulary lives in this file; it is registered there too.
///
/// The requirement is `_clean`, not `clean`: mirrors the `_loadModel`/
/// `loadModel` idiom used elsewhere (AD-7) — protocol requirements cannot
/// carry default arguments, so `contextBefore`/`contextAfter` (Story 4.4)
/// are defaulted to `nil` on the `clean(...)` overloads below instead,
/// keeping every pre-Story-4.4 call site unchanged.
protocol PostProcessing: AnyObject {
    func _clean(
        text: String,
        systemPrompt: String,
        contextBefore: String?,
        contextAfter: String?,
        configuration: PostProcessConfiguration
    ) async -> Result<String, PostProcessError>

    func testConnection(configuration: PostProcessConfiguration) async -> Result<String, PostProcessError>
}

extension PostProcessing {
    /// The original three-argument shape — no Cursor Context.
    func clean(
        text: String,
        systemPrompt: String,
        configuration: PostProcessConfiguration
    ) async -> Result<String, PostProcessError> {
        await _clean(text: text, systemPrompt: systemPrompt, contextBefore: nil, contextAfter: nil, configuration: configuration)
    }

    /// Story 4.4: Cursor Context, read once at recording start and forwarded
    /// here for exactly this one request (AD-5) — never logged, never
    /// persisted, and dropped by the pipeline immediately after this call.
    func clean(
        text: String,
        systemPrompt: String,
        contextBefore: String?,
        contextAfter: String?,
        configuration: PostProcessConfiguration
    ) async -> Result<String, PostProcessError> {
        await _clean(text: text, systemPrompt: systemPrompt, contextBefore: contextBefore, contextAfter: contextAfter, configuration: configuration)
    }

    /// The `clean(text:prompt:)` shape, with the current settings supplied.
    func clean(text: String, systemPrompt: String) async -> Result<String, PostProcessError> {
        await _clean(text: text, systemPrompt: systemPrompt, contextBefore: nil, contextAfter: nil, configuration: PostProcessSettings.current().configuration)
    }
}

// MARK: - Service

final class PostProcessService: PostProcessing, @unchecked Sendable {

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpShouldSetCookies = false
            // Fail fast instead of parking a request until the backend appears.
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func _clean(
        text: String,
        systemPrompt: String,
        contextBefore: String?,
        contextAfter: String?,
        configuration: PostProcessConfiguration
    ) async -> Result<String, PostProcessError> {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.emptyInput)
        }
        guard let url = PostProcessRequestBuilder.chatCompletionsURL(baseURL: configuration.baseURL) else {
            return .failure(.invalidEndpoint(configuration.baseURL))
        }

        let body = PostProcessRequestBuilder.body(
            text: text,
            systemPrompt: systemPrompt,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            configuration: configuration
        )
        let request: URLRequest
        do {
            request = try PostProcessRequestBuilder.urlRequest(url: url, body: body, timeout: configuration.timeout)
        } catch {
            return .failure(.malformedResponse("could not encode request"))
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        switch await send(request, timeout: configuration.timeout) {
        case .failure(let error):
            VocaLogger.warning(.postProcess, "clean failed — \(error.reason)")
            return .failure(error)
        case .success(let (data, statusCode)):
            let result = PostProcessResponseValidator.validate(data: data, statusCode: statusCode, input: text)
            let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
            switch result {
            case .success:
                VocaLogger.info(.postProcess, String(format: "clean succeeded in %.2fs", elapsed))
            case .failure(let error):
                VocaLogger.warning(.postProcess, "clean rejected — \(error.reason)")
            }
            return result
        }
    }

    /// Round-trips one minimal completion so the user finds out about a wrong
    /// port, an unloaded model, or a stopped server in one click. Returns the
    /// model identifier the backend answered with.
    func testConnection(configuration: PostProcessConfiguration) async -> Result<String, PostProcessError> {
        guard let url = PostProcessRequestBuilder.chatCompletionsURL(baseURL: configuration.baseURL) else {
            return .failure(.invalidEndpoint(configuration.baseURL))
        }

        let body = ChatCompletionRequest(
            model: configuration.model,
            messages: [.init(role: "user", content: "ping")],
            temperature: 0,
            maxTokens: 16,
            stream: false
        )
        let request: URLRequest
        do {
            request = try PostProcessRequestBuilder.urlRequest(url: url, body: body, timeout: configuration.timeout)
        } catch {
            return .failure(.malformedResponse("could not encode request"))
        }

        switch await send(request, timeout: configuration.timeout) {
        case .failure(let error):
            return .failure(error)
        case .success(let (data, statusCode)):
            guard (200...299).contains(statusCode) else {
                return .failure(.httpStatus(statusCode))
            }
            guard let decoded = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data) else {
                return .failure(.malformedResponse("could not decode chat completion"))
            }
            guard let model = decoded.model, !model.isEmpty else {
                return .failure(.malformedResponse("response did not name a model"))
            }
            return .success(model)
        }
    }

    // MARK: - Transport

    /// One request under two deadlines: `URLRequest.timeoutInterval` on the
    /// session, and an outer Task that cancels the transfer if URLSession has
    /// not honored its own (AD-6). Whichever fires first, the caller waits no
    /// meaningfully longer than the configured timeout.
    ///
    /// `URLRequest.timeoutInterval` is an idle timeout (time with no activity
    /// at all), not a wall-clock one — a backend that dribbles out a byte
    /// occasionally would keep resetting it indefinitely. The `watchdog` Task
    /// below is the one deadline here that is genuinely wall-clock, and is
    /// what actually bounds worst-case latency; treat it as authoritative.
    private func send(
        _ request: URLRequest,
        timeout: TimeInterval
    ) async -> Result<(Data, Int), PostProcessError> {
        let session = self.session
        let work = Task { () -> (Data, URLResponse) in
            try await session.data(for: request)
        }
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(max(timeout, 0.1) * 1_000_000_000))
            work.cancel()
        }
        defer { watchdog.cancel() }

        do {
            let (data, response) = try await work.value
            guard let http = response as? HTTPURLResponse else {
                return .failure(.malformedResponse("response was not HTTP"))
            }
            return .success((data, http.statusCode))
        } catch is CancellationError {
            return .failure(.timedOut(timeout))
        } catch let error as URLError {
            switch error.code {
            case .timedOut, .cancelled:
                return .failure(.timedOut(timeout))
            default:
                return .failure(.transport(error.localizedDescription))
            }
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }
}
