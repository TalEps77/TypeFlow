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
    /// The model handed back a run of the surrounding document text it was
    /// shown as reference (MAJOR 4, AD-5).
    case echoedCursorContext(sharedCharacters: Int)

    // MARK: Command Mode (Story 6.3)
    //
    // Command Mode overwrites text the user already has, so its rejections are
    // its own: the cleanup validator's length band and similarity floor are
    // tuned for an operation that must *not* change the wording, and a rewrite
    // legitimately does. These three are what remains once "the output must
    // resemble the input" is dropped.

    /// The rewrite ran away with itself. Not a similarity check — an expansion
    /// is a legitimate instruction — just a ceiling no honest rewrite reaches.
    case commandOutputTooLong(selectionCharacters: Int, outputCharacters: Int)

    /// The model handed back the spoken instruction instead of applying it.
    /// This is the one failure Command Mode exists to prevent: pasting "make
    /// this shorter" over the user's paragraph (AD-4).
    case commandEchoedInstruction

    /// A reasoning block leaked into the answer.
    case commandLeakedReasoning

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
        case .echoedCursorContext(let sharedCharacters):
            // Deliberately reports only the *length* of the overlap. The
            // overlapping text is document content; naming it here would put
            // it straight into a log line, which is the exact thing this
            // rejection exists to prevent (AD-5).
            return "output repeated \(sharedCharacters) characters of the surrounding document"
        case .commandOutputTooLong(let selection, let output):
            return "rewrite length \(output) is disproportionate to the \(selection)-character selection"
        case .commandEchoedInstruction:
            // Reports only that it happened. The instruction is the user's
            // speech and the output is derived from their document; neither
            // belongs in a log line (AD-5).
            return "model repeated the spoken instruction instead of applying it"
        case .commandLeakedReasoning:
            return "model leaked a reasoning block into the rewrite"
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

    /// Command Mode's request (Story 6.3). A separate builder rather than a
    /// flag on `body(...)`: it carries a different system prompt, a different
    /// user-message shape, and a token cap sized off the *selection* rather
    /// than off a transcript.
    static func commandBody(
        selection: String,
        instruction: String,
        systemPrompt: String,
        configuration: PostProcessConfiguration
    ) -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: configuration.model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: Prompts.commandUserMessage(selection: selection, instruction: instruction))
            ],
            temperature: configuration.temperature,
            maxTokens: commandMaxTokens(forSelectionCharacterCount: selection.count),
            stream: false
        )
    }

    /// More generous than `maxTokens(forInputCharacterCount:)`, because a
    /// rewrite may legitimately be asked to expand where a cleanup may not —
    /// but still a ceiling, so a runaway completion stops at ours rather than
    /// at the server's, where a truncated answer is indistinguishable from a
    /// complete one (BLOCKER 1's reasoning, applied here).
    static func commandMaxTokens(forSelectionCharacterCount selectionCharacterCount: Int) -> Int {
        max(512, selectionCharacterCount * 3)
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

    // MARK: - Cursor Context echo (MAJOR 4, AD-5)

    /// The longest run of characters the output may share with the Cursor
    /// Context it was shown before that output is treated as an echo of the
    /// user's document rather than a cleanup of their transcript.
    ///
    /// Neither guard above catches this on its own, which is the whole
    /// problem: a 100-character transcript answered with 95 clean characters
    /// plus 80 echoed from the document is 175 characters — inside the
    /// 0.5–2.0 length band — and shares nearly all of the transcript's
    /// bigrams, so the similarity check reads ~0.70 and waves it through.
    /// What lands is 80 characters of the user's document, typed into their
    /// app *and* written verbatim to history.json as `finalText`, which is
    /// the one way document text can reach a persisted record no schema
    /// constraint can stop.
    ///
    /// 40 characters is roughly a clause: long enough that ordinary phrase
    /// overlap between a dictation and the paragraph it continues does not
    /// trip it, short enough that no meaningful sentence of the document can
    /// slip through under it. A false positive costs exactly one dictation's
    /// cleanup — AD-2 falls back to the raw transcript, which is always safe.
    ///
    /// The bar is a bar, not a proof: an echo shorter than this is not caught
    /// here. Live-checking against Qwen3-4B-Instruct, a coaxed echo came back
    /// as a copied 26-character sentence fragment, which this lets through.
    /// Lowering the window is what would catch it, and is also what would
    /// start rejecting honest cleanups that happen to repeat a five-word
    /// phrase from the paragraph they are being written into — a dictation
    /// continuing a document *should* look like that document. The prompt
    /// (Prompts.cursorContextInstructions) is the first line of defense and
    /// held in every live run; this is the second, sized for the failure that
    /// actually matters: a whole clause or sentence of the document being
    /// typed into the user's app and written to history.
    static let contextEchoWindowLength = 40

    /// Length of the longest overlap found, or `nil` when the output shares
    /// no window of `contextEchoWindowLength` characters with either side of
    /// the context. Comparison is case- and whitespace-insensitive so a model
    /// that re-wraps or re-cases what it copied is caught just the same.
    static func cursorContextEcho(
        output: String,
        contextBefore: String?,
        contextAfter: String?,
        windowLength: Int = contextEchoWindowLength
    ) -> Int? {
        let contexts = [contextBefore, contextAfter].compactMap { $0 }.filter { !$0.isEmpty }
        guard !contexts.isEmpty else { return nil }

        let normalizedOutput = Array(normalizedForEchoComparison(output))
        guard normalizedOutput.count >= windowLength else { return nil }

        let normalizedContexts = contexts.map { normalizedForEchoComparison($0) }

        var longest = 0
        for start in 0...(normalizedOutput.count - windowLength) {
            let window = String(normalizedOutput[start..<(start + windowLength)])
            if normalizedContexts.contains(where: { $0.contains(window) }) {
                longest = max(longest, windowLength)
                // One window over the bar is already a rejection; there is
                // nothing a longer measurement would change, and the exact
                // figure is only ever used to say how much, never what.
                return longest
            }
        }
        return nil
    }

    /// Lowercased, with every run of whitespace collapsed to a single space.
    /// Nothing else is stripped: punctuation is exactly the kind of detail a
    /// copied clause carries, and removing it would only make the comparison
    /// looser than it needs to be.
    private static func normalizedForEchoComparison(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Turns a raw HTTP answer into either cleaned text or the reason it was
    /// refused. Never returns text it has not checked.
    ///
    /// - Parameters:
    ///   - contextBefore: the Cursor Context sent *with this request*, so the
    ///     answer can be checked against it in the same call frame (MAJOR 4).
    ///     Defaulted, so every call site that sends no context is unchanged.
    static func validate(
        data: Data,
        statusCode: Int,
        input: String,
        contextBefore: String? = nil,
        contextAfter: String? = nil
    ) -> Result<String, PostProcessError> {
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
        // Last, and only when context was actually sent: the two guards above
        // are both satisfied by a partial echo, so this is the one that keeps
        // document text out of the injected text and out of history (MAJOR 4).
        if let shared = cursorContextEcho(output: cleaned, contextBefore: contextBefore, contextAfter: contextAfter) {
            return .failure(.echoedCursorContext(sharedCharacters: shared))
        }

        return .success(cleaned)
    }
}

// MARK: - Command Mode response validation (Story 6.3)

/// Command Mode's acceptance rules, kept apart from
/// `PostProcessResponseValidator` on purpose.
///
/// That validator's job is to prove the model *cleaned* a transcript rather
/// than answering it, so it insists the output stay inside a 0.5–2.0 length
/// band and score above a bigram-similarity floor against the input. A rewrite
/// breaks both by design — "תקצר את זה למשפט אחד" is supposed to come back
/// much shorter, and "make this formal" is supposed to come back differently
/// worded. Reusing the cleanup rules here would reject the feature working
/// correctly; loosening them there would let a bad cleanup through. So the two
/// stay separate, and nothing below touches the cleanup validator.
///
/// What is left, once "the output must resemble the input" is dropped, is a
/// set of bounded sanity checks: the answer must be whole, non-empty, not the
/// instruction, not a reasoning block, and not runaway long. Anything else
/// aborts the operation and changes nothing (AD-4).
enum PostProcessCommandValidator {

    /// Ceiling on how much longer than the selection a rewrite may be. Set
    /// where a genuine "expand this into a paragraph" still fits and a model
    /// that has started generating an essay does not.
    static let maximumLengthRatio = 4.0

    /// Floor for the ceiling, so rewriting a three-word selection into a
    /// proper sentence is not rejected for arithmetic reasons.
    static let minimumLengthCeiling = 400

    /// Above this bigram similarity to the *instruction*, the output is the
    /// instruction rather than a rewrite. Deliberately high: an instruction
    /// and a rewrite of the same short Hebrew sentence share real vocabulary,
    /// and a false positive here costs the user a retry while a false negative
    /// costs them their paragraph.
    static let instructionEchoSimilarity = 0.9

    /// Markers of a leaked reasoning block. Qwen-family models emit these when
    /// a thinking variant is loaded by mistake, and the text after them is not
    /// a rewrite at all.
    static let reasoningMarkers = ["<think>", "</think>"]

    static func isWithinLengthCeiling(selection: String, output: String) -> Bool {
        let ceiling = max(minimumLengthCeiling, Int(Double(selection.count) * maximumLengthRatio))
        return output.count <= ceiling
    }

    /// Reuses `PostProcessResponseValidator.bigramSimilarity` rather than
    /// carrying a second copy of it — the measure is the same, only what it is
    /// measured against differs.
    static func echoesInstruction(output: String, instruction: String) -> Bool {
        let normalizedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedInstruction.isEmpty else { return false }
        if normalizedOutput.caseInsensitiveCompare(normalizedInstruction) == .orderedSame { return true }
        return PostProcessResponseValidator.bigramSimilarity(normalizedOutput, normalizedInstruction) >= instructionEchoSimilarity
    }

    static func leaksReasoning(_ output: String) -> Bool {
        reasoningMarkers.contains { output.localizedCaseInsensitiveContains($0) }
    }

    /// Turns a raw HTTP answer into either a rewrite fit to overwrite the
    /// user's selection with, or the reason it was refused. Never returns text
    /// it has not checked.
    static func validate(
        data: Data,
        statusCode: Int,
        selection: String,
        instruction: String
    ) -> Result<String, PostProcessError> {
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
        // A rewrite cut off at the token cap would replace the selection with
        // half a sentence — worse than not running at all.
        if let finishReason = choices[0].finishReason, finishReason != "stop" {
            return .failure(.malformedResponse("model stopped early: \(finishReason)"))
        }

        let rewritten = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rewritten.isEmpty else {
            return .failure(.emptyContent)
        }
        guard !leaksReasoning(rewritten) else {
            return .failure(.commandLeakedReasoning)
        }
        guard !echoesInstruction(output: rewritten, instruction: instruction) else {
            return .failure(.commandEchoedInstruction)
        }
        guard isWithinLengthCeiling(selection: selection, output: rewritten) else {
            return .failure(.commandOutputTooLong(selectionCharacters: selection.count, outputCharacters: rewritten.count))
        }

        return .success(rewritten)
    }
}

// MARK: - Protocol

/// Declared here rather than in ServiceProtocols.swift only because the
/// protocol's vocabulary lives in this file; it is registered there too.
///
/// The requirement is `_clean`, not `clean`: mirrors the `_loadModel`/
/// `loadModel` idiom used elsewhere (AD-7). Protocol requirements cannot
/// carry default arguments, so rather than defaulting anything, the single
/// five-argument requirement below is fronted by three distinct `clean(...)`
/// overloads in the extension — one per call shape that existed or was added
/// — and only the Story 4.4 overload takes Cursor Context at all. That is
/// what keeps every pre-Story-4.4 call site compiling unchanged (MINOR 14).
protocol PostProcessing: AnyObject {
    func _clean(
        text: String,
        systemPrompt: String,
        contextBefore: String?,
        contextAfter: String?,
        configuration: PostProcessConfiguration
    ) async -> Result<String, PostProcessError>

    /// Story 6.3: rewrite `selection` according to `instruction`. A separate
    /// requirement from `_clean` because everything about it differs — prompt,
    /// message shape, token cap, and acceptance rules — and because a caller
    /// must not be able to reach cleanup's identity fallback from here.
    ///
    /// `selection` is the user's document text (AD-5): it goes into one
    /// request and is never logged or persisted on the way.
    func _command(
        selection: String,
        instruction: String,
        systemPrompt: String,
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

    /// Story 6.3, matching the `_clean`/`clean` idiom.
    func command(
        selection: String,
        instruction: String,
        systemPrompt: String = Prompts.commandModeSystemPrompt,
        configuration: PostProcessConfiguration
    ) async -> Result<String, PostProcessError> {
        await _command(selection: selection, instruction: instruction, systemPrompt: systemPrompt, configuration: configuration)
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
            // A cache *policy* governs what a request is allowed to read, not
            // what the session is allowed to store: an ephemeral session still
            // builds an in-memory `URLCache`, and a response containing the
            // user's cleaned transcript — and, with Story 4.4 on, the document
            // text sent alongside it — would sit in it. Removing the cache
            // outright is the only thing that guarantees nothing is written at
            // all (MINOR 2, AD-5).
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
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
            let result = PostProcessResponseValidator.validate(
                data: data,
                statusCode: statusCode,
                input: text,
                contextBefore: contextBefore,
                contextAfter: contextAfter
            )
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

    func _command(
        selection: String,
        instruction: String,
        systemPrompt: String,
        configuration: PostProcessConfiguration
    ) async -> Result<String, PostProcessError> {
        guard !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.emptyInput)
        }
        guard let url = PostProcessRequestBuilder.chatCompletionsURL(baseURL: configuration.baseURL) else {
            return .failure(.invalidEndpoint(configuration.baseURL))
        }

        let body = PostProcessRequestBuilder.commandBody(
            selection: selection,
            instruction: instruction,
            systemPrompt: systemPrompt,
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
            VocaLogger.warning(.commandMode, "command failed — \(error.reason)")
            return .failure(error)
        case .success(let (data, statusCode)):
            let result = PostProcessCommandValidator.validate(
                data: data,
                statusCode: statusCode,
                selection: selection,
                instruction: instruction
            )
            let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
            switch result {
            case .success:
                VocaLogger.info(.commandMode, String(format: "command succeeded in %.2fs", elapsed))
            case .failure(let error):
                VocaLogger.warning(.commandMode, "command rejected — \(error.reason)")
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
