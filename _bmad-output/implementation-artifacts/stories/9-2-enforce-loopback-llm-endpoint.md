# Story 9.2: Enforce a loopback-only LLM endpoint

Status: done

<!-- Remediation story. Source: adversarial acceptance audit, 2026-08-22.
Violates Epic 2 AC ("it targets only the configured loopback endpoint" —
epics.md:280-282, Story 2.2) and NFR-1 ("Offline-first — only loopback
network traffic" — epics.md:60). -->

## Story

As a user relying on TypeFlow's offline-first guarantee,
I want the app to refuse to send my transcript to any non-loopback host,
So that a mistyped or malicious endpoint can never exfiltrate what I dictate.

## Context / Defect

Epic 2's AC for `PostProcessService` states: "it targets only the configured
loopback endpoint, and the app remains fully functional with no internet
route" (epics.md:280-282). Nothing in the code enforces this.

`PostProcessRequestBuilder.endpointURL(baseURL:path:)`
(`Sources/VocaMac/Services/PostProcessService.swift:156-170`) validates only
that the string parses to a `URL` with a scheme and a host — any host,
including a public one. `PostProcessService._clean`, `_command`, and
`testConnection` (same file, ~lines 737-876) all build their request off
that URL with no further check, then hand it straight to `URLSession`. If
the user's `postProcessBaseURL` (`AppState.swift:133`, default
`http://localhost:1234` from `PostProcessSettings.Default.baseURL`) is ever
set to a non-loopback host — by mistake, by a bad paste, or by something
that edits the setting programmatically — every transcript for post-
processing and every Command Mode instruction+selection goes out over the
network with zero resistance.

The only existing loopback awareness is cosmetic: `PostProcessSettingsTab
.isEndpointLoopback` (`Sources/VocaMac/Views/PostProcessSettingsTab.swift:
20-27`) shows an orange warning label when the host isn't
`localhost`/`127.0.0.1`/`::1` — "a warning rather than a hard block" per its
own doc comment — and does not stop the request. It also only matches the
literal string `127.0.0.1`, not the full `127.0.0.0/8` loopback range.

The audit found the AC-named test tautological: it exercises the URL
building/parsing logic without ever asserting that a non-loopback host is
rejected before a network call is attempted.

## Acceptance Criteria

1. A service-boundary check runs before any HTTP request leaves
   `PostProcessService` (`_clean`, `_command`, `testConnection`): the
   configured host must resolve as loopback — `localhost`, the
   `127.0.0.0/8` range (not just the literal `127.0.0.1`), or `::1`.
2. When the host is non-loopback, the request is never issued (no call
   reaches `URLSession`/the injected transport), and the caller receives
   the existing transparent-degrade path — i.e. `_clean` behaves exactly
   like any other rejection today: the pipeline falls back to the raw
   transcript (AD-2), with no modal/dialog. `_command` returns a
   `PostProcessError` the same way it does for its other rejections (Command
   Mode's abort-and-change-nothing behavior, AD-4) — do not invent new
   error-handling paths at call sites; reuse `PostProcessError`.
3. A unit test using a mock/injected `URLSession` (or a fake transport, per
   whatever `PostProcessServiceTests.swift` already uses to avoid real
   sockets — see its loopback `TCP` listener helper) asserts **zero**
   requests are issued for a non-loopback `baseURL`.
4. The tautological AC-2.2-6 test is replaced with real accept/reject
   cases: `http://localhost:1234`, `http://127.0.0.1:1234`, and
   `http://[::1]:1234` are accepted (request is attempted); `http://
   192.168.1.10:1234` and `http://evil.example.com` are refused (request is
   never attempted). Include at least one case elsewhere in `127.0.0.0/8`
   (e.g. `http://127.0.0.2:1234`) to prove the check isn't hardcoded to the
   single literal address.
5. Full suite green (`swift test`).

## Tasks / Subtasks

- [x] Task 1 — Loopback predicate (AC: 1, 4)
  - [x] Add a pure, testable loopback check — e.g.
        `PostProcessRequestBuilder.isLoopback(host: String) -> Bool` (or a
        module-level function/enum case near `endpointURL`, matching this
        file's existing "pure functions live in
        `PostProcessRequestBuilder`/`PostProcessResponseValidator`" pattern
        so it stays unit-testable with no network per NFR-6). Must accept
        `localhost`, any `127.x.x.x` (the full `127.0.0.0/8` block — parse
        the first octet, don't string-match `"127.0.0.1"` only), and `::1`;
        reject everything else, case-insensitively on the host string.
  - [x] Consider whether `PostProcessSettingsTab.isEndpointLoopback`
        (`PostProcessSettingsTab.swift:20-27`) should now call the same
        predicate instead of carrying its own narrower copy — smaller
        surface to keep in sync, and fixes the `127.0.0.0/8` gap there too.
        Not required by the ACs above, but do it if it's a small diff;
        otherwise leave the UI file alone and note it.
- [x] Task 2 — Enforce at the service boundary (AC: 1, 2)
  - [x] In `PostProcessService._clean` and `_command`
        (`PostProcessService.swift:737, 789`), after resolving `url` via
        `PostProcessRequestBuilder.chatCompletionsURL(baseURL:)` and before
        constructing/sending the request, check the resolved URL's host
        against the loopback predicate. On failure, return
        `.failure(.invalidEndpoint(configuration.baseURL))` (the existing
        error case already used for an unparseable endpoint at
        `PostProcessService.swift:748, 800` — reuse it rather than adding a
        new `PostProcessError` case, since "not loopback" and "not a valid
        endpoint" are both "this endpoint cannot be used" from the caller's
        perspective).
  - [x] Apply the same guard in `testConnection`
        (`PostProcessService.swift:842-876`) so "Test Connection" in
        Settings reports the same rejection instead of silently attempting
        a real network call.
  - [x] Confirm no request is constructed/sent when the guard fires — the
        check must come before the `send(request, ...)` call, not after.
- [x] Task 3 — Tests (AC: 3, 4)
  - [x] In `Tests/VocaMacTests/PostProcessServiceTests.swift`, find and
        replace the existing loopback/AC-2.2-6 test (search for "loopback"
        — there is already a loopback TCP listener helper near line 646 for
        other tests in this file; reuse its pattern for the "accepted"
        cases so a genuine local listener answers, proving the request was
        actually attempted).
  - [x] Add explicit accept cases: `localhost`, `127.0.0.1`, `127.0.0.2`,
        `[::1]` (all pointed at the test's loopback listener or a stub that
        proves a request reached the transport).
  - [x] Add explicit reject cases: `192.168.1.10`, `evil.example.com` —
        assert `.failure(.invalidEndpoint(...))` and that the mock
        transport / listener saw **zero** connections.
- [x] Task 4 — Full suite (AC: 5)
  - [x] `swift test` green.

## Dev Notes

- Repo is Swift/SwiftPM (Xcode 26.6 installed); baseline 784 tests green.
- `PostProcessConfiguration.baseURL` (`Sources/VocaMac/Models/
  PostProcessSettings.swift:99-116`) is the single source of truth for the
  configured endpoint; it flows into `PostProcessService` per-call (not
  held on the service), per the existing doc comment there.
- `PostProcessRequestBuilder.endpointURL` already does host parsing via
  `URL(string:)?.host` (`PostProcessService.swift:166`) — reuse that
  parsed `URL`'s `.host` for the loopback check rather than re-parsing the
  raw string a second time.
- Do not touch `PostProcessResponseValidator` or
  `PostProcessCommandValidator` — this defect is entirely at the
  request-issuing boundary, not response validation.
- `PostProcessSettingsTab.isEndpointLoopback` is a UI-only cosmetic warning
  today (its own doc comment says so) — leave its behavior (warn, don't
  block) as-is in the UI; the enforcement being added here is at the
  service layer, which is the actual network boundary (AD-6).
- No commits by the dev agent.

### Project Structure Notes

- Primary changes: `Sources/VocaMac/Services/PostProcessService.swift`
  (predicate + two/three call sites) and
  `Tests/VocaMacTests/PostProcessServiceTests.swift`. Optionally
  `Sources/VocaMac/Views/PostProcessSettingsTab.swift` if reusing the new
  predicate there (small diff only).

### References

- [Source: Sources/VocaMac/Services/PostProcessService.swift:140-244, 709-923]
- [Source: Sources/VocaMac/Views/PostProcessSettingsTab.swift:20-27]
- [Source: Sources/VocaMac/Models/PostProcessSettings.swift:99-116]
- [Source: Tests/VocaMacTests/PostProcessServiceTests.swift:646 (existing loopback listener helper)]
- [Source: _bmad-output/planning-artifacts/epics.md:60, 280-288 (NFR-1; Epic 2, Story 2.2 AC)]

## Dev Agent Record

### Agent Model Used

claude-opus-5[1m] (BMAD dev agent, `bmad-build` step-03)

### Debug Log References

- `swift build --build-tests` — clean, no warnings introduced.
- `swift test --filter "testLoopback|testNonLoopback"` — 5 new tests ran and passed
  (confirmed by name, so none is silently unregistered).
- `swift test` — 794 tests, 1 skipped, 0 failures.

Review remediation pass (2026-08-22):

- `swift build --build-tests` — clean, no new warnings.
- **MINOR-4** — the working filter is
  `swift test --filter "PostProcessRequestBuilderTests|PostProcessServiceTransportTests"`.
  There is no `PostProcessServiceTests` **class** (only a file of that name),
  so filtering on it runs zero tests and still exits 0. Post-remediation:
  **26 tests, 0 failures** in those two classes.
- Mutation checks (each reverted immediately afterward):
  - `send` without the delegate → redirect test fails, and `clean` returns
    success from the redirect target.
  - `_command` / `testConnection` guards inverted → accept test fails on both.
- `swift test` — **796 tests, 1 skipped, 0 failures.** (794 → 796: +1 for the
  new redirect test, +1 from a sibling story agent working the same tree.)

### Completion Notes List

- **AC 1** — `PostProcessRequestBuilder.isLoopback(host:)` is a pure predicate
  living next to `endpointURL`, matching the file's "pure functions are
  unit-testable with no network" pattern (NFR-6). It lowercases, strips the
  brackets Foundation may keep around an IPv6 literal, accepts `localhost` and
  `::1`, and otherwise *parses* the dotted quad — four ASCII-numeric octets each
  ≤ 255, first octet 127 — so the whole `127.0.0.0/8` block passes while
  `127.example.com`, `1270.0.0.1`, and `128.0.0.1` do not. A four-line
  `isLoopback(url:)` overload keeps the three call sites to one line each.
- **AC 2** — The guard sits immediately after the `chatCompletionsURL` resolution
  and before the body/`URLRequest` is built in `_clean`, `_command`, and
  `testConnection`, and returns the pre-existing
  `.invalidEndpoint(configuration.baseURL)`. No new `PostProcessError` case and no
  new call-site handling: `_clean` degrades to the raw transcript exactly as it
  does for an unparseable endpoint (AD-2), `_command` aborts and changes nothing
  (AD-4). `_clean`/`_command` log a one-line warning on their existing channels
  (`.postProcess` / `.commandMode`), matching how other rejections are logged;
  `testConnection` has no logging today, so none was added.
- **AC 3/4** — The tautological `testRequestTargetsOnlyTheConfiguredLoopbackHost`
  is gone. Replacing it: three predicate tests plus two service-boundary tests
  driven by a new `RecordingURLProtocol` injected via
  `PostProcessService(session:)`. It counts requests in `startLoading()`, which
  runs exactly once per request URLSession decided to issue — a stricter signal
  than `canInit`, which can fire more than once. `localhost`, `127.0.0.1`,
  `127.0.0.2`, and `[::1]` each record exactly 1 request; `192.168.1.10` and
  `evil.example.com` record **0** across all three entry points and return
  `.invalidEndpoint`. The accept half is what keeps the reject half honest — a
  service that sent nothing at all would fail it.
- **Task 1 optional item — done.** `PostProcessSettingsTab.isEndpointLoopback` now
  delegates to the shared predicate (4 lines swapped), which removes the duplicate
  and fixes its `127.0.0.0/8` gap. Its behavior is unchanged: still a warning
  label, still not a block, still returns "loopback" for an unparseable URL. The
  enforcement is at the service layer, which is the real network boundary (AD-6).
- **Test count** — baseline 784; this story removes 1 test and adds 5. The suite
  reports 794 because sibling story agents (9-1/9-3/9-4) were adding tests in the
  same working tree concurrently. 0 failures.
- No `.html` companion was generated for this story: no story in
  `_bmad-output/implementation-artifacts/stories/` has one, and the wrap-up
  (close-story) step owns that regeneration.
- No commits made, per the story's Dev Notes.

### File List

- `Sources/VocaMac/Services/PostProcessService.swift` — added
  `PostProcessRequestBuilder.isLoopback(host:)` / `isLoopback(url:)` (after
  `endpointURL`); added the loopback guard in `_clean`, `_command`, and
  `testConnection`. *Review pass:* added the `RedirectBlocker`
  `URLSessionTaskDelegate`, attached it per task in `send`, added the `3xx` →
  `.httpStatus` conversion, and dropped the whitespace trim from
  `isLoopback(host:)`. *Adversarial pass:* set
  `configuration.connectionProxyDictionary = [:]` in `init` so a system HTTP
  proxy/PAC cannot divert the POST body off-box (`:791-800`); added the missing
  refusal log line to the `testConnection` guard (`:928`); removed the redundant
  `3xx` guard in `send` (`:995-1002`) — every caller already rejects non-2xx
  with the identical `.httpStatus`, so it was unobservable and unpinnable.
- `Sources/VocaMac/Views/PostProcessSettingsTab.swift` — `isEndpointLoopback` now
  calls the shared predicate instead of its own narrower copy. *Review pass:*
  the warning label and the doc comment now describe the enforced block and the
  degrade-to-raw consequence instead of claiming the app will send over the
  network. *Adversarial pass:* `isEndpointLoopback` (`:24-38`) now resolves via
  `PostProcessRequestBuilder.chatCompletionsURL` + `isLoopback(url:)` — exactly
  as the service does — instead of a bare `URL(string:)`, so a padded or
  `/v1`-suffixed non-loopback URL warns instead of reading as fine; an
  unresolvable string warns too, while an empty field stays silent because it
  falls back to the loopback default. Label advice corrected to `localhost`,
  `127.0.0.1`, `[::1]` (`:66`).
- `Tests/VocaMacTests/PostProcessServiceTests.swift` — replaced
  `testRequestTargetsOnlyTheConfiguredLoopbackHost` with
  `testLoopbackHostsAreAccepted`, `testNonLoopbackHostsAreRejected`,
  `testLoopbackCheckReadsTheHostOfAResolvedEndpoint`,
  `testLoopbackEndpointsReachTheTransport`,
  `testNonLoopbackEndpointsNeverReachTheTransport`; added the
  `RecordingURLProtocol` test transport. *Review pass:* added
  `testARedirectFromTheConfiguredEndpointIsNeverFollowed` and the
  `StubHTTPListener` two-socket helper; extended
  `testLoopbackEndpointsReachTheTransport` to `command` + `testConnection`;
  added the whitespace-host reject cases. *Adversarial pass:* `StubHTTPListener`
  now sets `SO_NOSIGPIPE` on each accepted client socket (`:897-905`) — without
  it, URLSession closing the connection before the canned response is written
  raises `SIGPIPE`, which kills the whole `xctest` process (exit 141) instead of
  failing one test.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — `9-2` → `review`.

## Change Log

| Date | Change | By |
| --- | --- | --- |
| 2026-08-22 | Loopback enforced at the `PostProcessService` request boundary (`_clean`, `_command`, `testConnection`) via a new parsed `127.0.0.0/8`-aware predicate; non-loopback endpoints now degrade transparently through the existing `.invalidEndpoint` path with zero requests issued. Tautological AC-2.2-6 test replaced with real accept/reject coverage. Status → review. | Dev agent (claude-opus-5) |
| 2026-08-22 | Review remediation. **MAJOR-1:** HTTP redirects are now refused outright — a `RedirectBlocker` task delegate returns `nil` from `willPerformHTTPRedirection` and `send` turns any unfollowed `3xx` into `.httpStatus`, closing the hole where a `307` from the configured loopback port re-POSTed the whole transcript off-box; covered by a two-listener test that fails (and leaks) without the fix. **MEDIUM-2:** Settings copy and doc comment now state the endpoint is refused and post-processing degrades to the raw transcript. **MEDIUM-3:** accept-side coverage extended to `command` and `testConnection` — inverting either guard now fails the suite. **MINOR-5:** whitespace trim dropped from the loopback predicate, so `localhost%20` is refused. **MINOR-4:** no code change — the test classes are `PostProcessRequestBuilderTests` / `PostProcessServiceTransportTests`; there is no `PostProcessServiceTests` class, so that filter runs zero tests and exits 0. With MAJOR-1 closed, the NFR-1 claim stands. Status stays `review` for re-review. | Dev agent (claude-opus-5) |
| 2026-08-22 | Post-approval adversarial findings closed: proxy, SIGPIPE, UI parity. **BLOCKER — proxy diversion:** the session never opted out of system proxy resolution, so an HTTP proxy or PAC script received the full transcript POST while the loopback guard saw only a `127.0.0.1` URL; `configuration.connectionProxyDictionary = [:]` now disables proxying for this session. Probe-confirmed both ways: with an explicit proxy configured the body (`SECRET-TRANSCRIPT`) reached the proxy and the origin got nothing; with `[:]` the proxy saw no new connection and the origin received the request. **BLOCKER — SIGPIPE:** `StubHTTPListener` wrote via `Darwin.send` with no `SO_NOSIGPIPE`, so URLSession dropping the connection first killed the entire `xctest` process (exit 141) rather than failing one test; `SO_NOSIGPIPE` is now set beside the existing `SO_RCVTIMEO`, and the redirect test ran 8/8 clean. **MAJOR — UI/service disagreement:** `isEndpointLoopback` parsed the raw string with `URL(string:)` while the service resolves through `PostProcessRequestBuilder`, so padded non-loopback URLs (`"  http://evil.example.com/v1  "`, `" http://10.0.0.5:1234 "`) were silently refused by the service with no UI warning — probe-confirmed `URL(string:).host` is `nil` for both while the builder resolves them to `evil.example.com` / `10.0.0.5`. The predicate now resolves exactly as the service does and treats an unresolvable URL as warn-worthy; the empty field still stays silent because it falls back to the loopback default. Label advice corrected from the wrong `127.x.x.x` / bare `::1` to `localhost`, `127.0.0.1`, `[::1]`. **Advisories:** added the missing refusal log line to the `testConnection` guard; deleted the redundant `3xx` guard in `send` rather than leaving it untested — all three callers already reject non-2xx with the identical `.httpStatus`, so no test could distinguish it. Suite 796 tests, 0 failures, 1 skipped. Status stays `review`. | Dev agent (claude-opus-5) |

## Code Review

**Reviewer:** adversarial review agent (fresh context, nothing from the Dev Agent
Record taken on trust) · **Date:** 2026-08-22 · **Model:** claude-opus-5[1m]

### Verdict: CHANGES REQUESTED

The predicate and the three guards are correct, well-placed, and survived a
deliberate hunt for parser bypasses — I could not find a host string that the
check accepts but that resolves off-box. Two things block sign-off anyway: the
story's own threat statement ("a mistyped or **malicious** endpoint can never
exfiltrate what I dictate") is still open through HTTP redirects, which I
reproduced; and the Settings UI now tells the user the exact opposite of what
the app does. The literal AC checklist is arguably satisfiable without fixing
MAJOR-1, so it can be split into a follow-up — but this story must not be
recorded as closing NFR-1 while it stands.

### MAJOR

**MAJOR-1 — Redirects are followed to any host; the configured loopback server
can bounce the transcript off-box.** `PostProcessService.init` builds
`URLSession(configuration:)` with **no delegate** (`PostProcessService.swift:747-767`)
and `send(_:timeout:)` is a plain `session.data(for: request)`
(`PostProcessService.swift:936-942`). Nothing implements
`urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`
and nothing inspects `Location`. Reproduced against that exact session config:
a loopback server answering `307` re-POSTed the **complete request body** to
the redirect target, and the loopback predicate never ran a second time —
final URL was whatever `Location` named. Substitute a public host and the
dictated transcript leaves the machine. No privilege is needed to mount this:
any unprivileged local process that owns (or wins the race for) the configured
high loopback port is the "malicious endpoint" the story names. 307/308
preserve the body; even 302 (which downgrades to GET) leaks liveness, headers,
and the URL. Fix: a delegate whose redirect handler returns `nil`, or re-runs
`isLoopback` on `newRequest.url`, plus a test asserting a 307 to a non-loopback
host is not followed.

### MEDIUM

**MEDIUM-2 — The Settings UI now states the opposite of the enforced
behavior.** `PostProcessSettingsTab.swift:56` still reads "This endpoint is not
on localhost — TypeFlow **will send** transcripts to it over the network," and
the doc comment at `:20-21` still says "a warning rather than a hard block."
Neither is true any more. A user pointing at a real LAN LLM
(`http://192.168.1.50:1234` — an ordinary LM Studio setup) now gets a silent
degrade-to-raw on every dictation with no explanation, and Test Connection
reports `invalid endpoint: http://192.168.1.50:1234`
(`PostProcessService.swift:57-58`), which names the wrong cause. This is a spec
gap the story handed the dev ("leave its behavior as-is in the UI"), not dev
disobedience — but shipping enforcement while the UI calls it a warning is
worse than either alone. Update the copy and the comment to say *blocked*, and
give the refusal a reason the user can act on.

**MEDIUM-3 — Verification gap: the accept half only covers `_clean`.**
`testLoopbackEndpointsReachTheTransport`
(`Tests/VocaMacTests/PostProcessServiceTests.swift:672-683`) calls only
`service.clean(...)`. `testNonLoopbackEndpointsNeverReachTheTransport` covers
all three entry points, but nothing proves `_command` or `testConnection` still
*send* for a loopback host — invert either of those two guards and the suite
stays green. The completion note's argument ("the accept half is what keeps the
reject half honest") holds for `clean` only. Two added lines close it.

### MINOR

**MINOR-4 — `swift test --filter PostProcessServiceTests` runs zero tests and
exits 0.** No class carries that name; the file holds
`PostProcessRequestBuilderTests` and `PostProcessServiceTransportTests`. The
command emits "warning: No matching test cases were run" and still exits 0 — a
green-looking run that verified nothing. Anyone re-verifying this story from
the filename will be misled. Actual run:
`swift test --filter "PostProcessRequestBuilderTests|PostProcessServiceTransportTests"`
→ **24 tests, 0 failures**, all five new tests present by name. The Debug Log's
`--filter "testLoopback|testNonLoopback"` claim checks out.

**MINOR-5 — The predicate trims whitespace off the host, which can only loosen
it.** `isLoopback(host:)` starts with `.trimmingCharacters(in: .whitespaces)`
(`PostProcessService.swift:178`). `URL.host` is percent-**decoded**, so
`http://localhost%20:1234` yields host `"localhost "` → trimmed → **accepted**,
while the wire authority stays `localhost%20`. Not exploitable — I probed the
decoded-vs-wire divergence specifically (`%00` truncation,
`%31%32%37%2e%30%2e%30%2e%31`, U+3002 ideographic dot, backslash-authority) and
every case lands fail-closed, because decoding can shorten a host but never
graft a new authority onto it. The trim buys nothing and widens the accepted
set for no reason; drop it.

### LOW

**LOW-6 — Legitimate loopback spellings that are refused** (all fail-*closed*,
so safe; listing them so a future bug report isn't mistaken for a regression):
`localhost.` and `127.0.0.1.` (trailing root dot), `[::ffff:127.0.0.1]`
(IPv4-mapped IPv6), `[0:0:0:0:0:0:0:1]` (expanded `::1`), `127.1` (short form),
`0177.0.0.1` and `2130706433` (octal/decimal forms that BSD `inet_aton` does
resolve to 127.0.0.1). `0.0.0.0` is also refused although macOS routes it to
loopback. Refusing is the right direction in every case — worth one comment.
Note also that AC 4's `127.0.0.2` is unreachable on a stock macOS without
`ifconfig lo0 alias 127.0.0.2`; the /8 check is still correct per RFC 1122, and
the test only exercises the predicate/transport, so nothing is wrong here.

**LOW-7 — Scheme is unvalidated.** `endpointURL` requires only a non-nil scheme
(`PostProcessService.swift:166`), so `ftp://127.0.0.1:1234` clears the loopback
guard. Harmless in practice (URLSession errors out), but the guard would read
better as scheme ∈ {http, https} *and* loopback.

**LOW-8 — Pre-existing, out of scope.** `endpointURL` string-concatenates the
path, so a baseURL carrying a fragment or query yields
`http://127.0.0.1:1234#x/v1/chat/completions` — the path is swallowed into the
fragment and the request lands on `/`. Not introduced by this story.

### Verified — tried to break these and could not

- **Guard placement.** `:785`, `:841`, `:889` all sit after URL resolution and
  before the body and `URLRequest` are built. Confirmed by reading, and
  independently by the zero-request assertion.
- **Userinfo tricks resolve correctly in both directions.**
  `http://evil.example.com@127.0.0.1:1234` → host `127.0.0.1`, accepted, and it
  genuinely connects to loopback. `http://127.0.0.1@evil.example.com:1234` →
  host `evil.example.com`, refused. Same for `user:pass@127.0.0.1`.
- **Parser bypasses.** `LOCALHOST` accepted; `127.example.com`, `1270.0.0.1`,
  `128.0.0.1`, `126.255.255.255`, `localhost.evil.com`, `127.0.0.256`, and
  `localhost。evil.example.com` (U+3002, which Foundation normalizes to a real
  dot) all refused. `①27.0.0.1` normalizes to `127.0.0.1` and is accepted —
  correctly, it connects to loopback. `127.00.0.1` accepted, also correct.
- **No TOCTOU.** `url` is resolved once, checked, and that same value is handed
  to `urlRequest(url:...)`; `configuration` is a value type and `baseURL` is
  never re-read between check and send.
- **No other egress in the service.** `modelsURL` (`:152`) is dead code, called
  from nowhere. `UpdateChecker` is the only other `URLSession` user in
  `Sources/` and is deliberately internet-facing (out of scope).
- **Degrade-to-raw is real, not asserted.** `_clean` failure →
  `Sources/VocaMac/Pipeline/Stages/PostProcessStage.swift:110-113` returns
  `StageResult(text: text, outcome: .failed(reason:))` — raw transcript, no
  modal (AD-2). `_command` failure →
  `Sources/VocaMac/Services/CommandModeCoordinator.swift:198-200` returns
  `.failure(.llm(error))` before anything is written to the document (AD-4).
- **`RecordingURLProtocol` observes real behavior.** It counts in
  `startLoading()`, which fires once per request URLSession actually issues —
  the right hook, and stricter than `canInit`.

### AC status

| AC | Status | Note |
| --- | --- | --- |
| 1 — guard before any request in `_clean`/`_command`/`testConnection` | Met | All three verified by reading and by test |
| 2 — no request issued; existing degrade paths reused | Met | Degrade-to-raw and command-abort traced to their call sites |
| 3 — zero requests asserted via injected transport | Met | `RecordingURLProtocol`, counts in `startLoading()` |
| 4 — tautological test replaced with accept/reject cases | Met, thin | See MEDIUM-3: accept side covers `clean` only |
| 5 — full suite green | Met | 24/24 in the two relevant classes; see MINOR-4 on the filter name |
| Story goal — "a malicious endpoint can never exfiltrate" | **Not met** | MAJOR-1, redirects |

### Required before this closes

1. [x] MAJOR-1 — block or re-check redirects, with a test. If deferred, open the
   follow-up story and drop the NFR-1 claim from this one's Change Log.
2. [x] MEDIUM-2 — UI copy and doc comment must match enforced behavior.
3. [x] MEDIUM-3 — extend the accept test to `command` and `testConnection`.
4. [x] MINOR-5 — drop the whitespace trim from the loopback predicate.
5. [x] MINOR-4 — no code change; the correct filter is recorded in the Change
   Log and the Debug Log below.

### Review Remediation (2026-08-22)

**MAJOR-1 — redirects blocked outright.** `RedirectBlocker`
(`Sources/VocaMac/Services/PostProcessService.swift:753-766`) is a
`URLSessionTaskDelegate` whose `willPerformHTTPRedirection` calls
`completionHandler(nil)`. It is attached **per task** in `send`
(`PostProcessService.swift:973`, `session.data(for:delegate:)`) rather than to
the session, so an injected session gets the same rule as the built-in one
(`redirectBlocker` is held at `:775`). The unfollowed `3xx` comes back as the
response, and `send` (`PostProcessService.swift:986-991`) converts any `300...399` into
`.failure(.httpStatus(code))` so no caller can mistake it for an answer — it
lands on the existing degrade path (`_clean` → raw transcript, AD-2;
`_command` → abort, AD-4). Fail-closed by design: LM Studio and every other
OpenAI-compatible backend answer chat-completions directly, so nothing
legitimate is refused.

**MEDIUM-2 — Settings copy now matches enforcement.**
`PostProcessSettingsTab.swift:58` reads "This endpoint is not on localhost.
TypeFlow never sends transcripts off this machine, so it will refuse to contact
it — post-processing is skipped and your raw transcript is used. Use a loopback
address (localhost, 127.x.x.x, or ::1)." The doc comment at `:20-23` no longer
claims "a warning rather than a hard block"; it states that the service
enforces the block and that this label only explains it.

**MEDIUM-3 — accept side now covers all three entry points.**
`testLoopbackEndpointsReachTheTransport` drives `clean`, `command`, and
`testConnection` and asserts the running request count 1 → 2 → 3 per host.

**MINOR-5 — trim dropped.** `isLoopback(host:)`
(`PostProcessService.swift:177-182`) matches the host verbatim (`.lowercased()`
only); the reason the
trim was wrong (percent-decoded `URL.host` vs. the wire authority) is now a doc
comment, and `"localhost "` / `" 127.0.0.1"` are reject cases in
`testNonLoopbackHostsAreRejected`.

**Mutation-verified, not just green.** Each new assertion was proven to fail
against the unfixed code before being accepted:

- Reverting `send` to a bare `session.data(for: request)` →
  `testARedirectFromTheConfiguredEndpointIsNeverFollowed` fails on *both*
  "the transcript must never reach the redirect target" and a `nil` error —
  i.e. `clean` **succeeded** off-box. That is the reviewer's exfiltration,
  reproduced and then closed.
- Inverting the `_command` guard and the `testConnection` guard →
  `testLoopbackEndpointsReachTheTransport` fails on both, for all four hosts.

**Not done, deliberately.** MEDIUM-2's second half — "`invalid endpoint:
http://192.168.1.50:1234` names the wrong cause" — would mean a new
`PostProcessError` case or reworded `reason`, which the story's AC 2 explicitly
forbids ("do not invent new error-handling paths… reuse `PostProcessError`").
The Settings label now supplies the actionable explanation instead. Worth a
follow-up if the Test Connection wording still reads wrong to the reviewer.
LOW-6/7/8 remain open by the reviewer's own assessment (all fail-closed or
pre-existing).

### Re-review (2026-08-22)

**Reviewer:** fresh adversarial reviewer (nothing in the Dev Agent Record or the
Remediation section taken on trust; every claim re-derived from source, from
independent probes written outside the repo, and from executed test runs)
· **Model:** claude-opus-5[1m]

#### Verdict: APPROVED

All five "Required before this closes" items are genuinely closed. MAJOR-1 in
particular was re-verified against an *independent* reproduction rather than
against the repo's own test — the exfiltration was real, and it is now shut.

#### MAJOR-1 — closed, independently reproduced both ways

- `RedirectBlocker` (`PostProcessService.swift:753-765`) is a
  `URLSessionTaskDelegate` returning `completionHandler(nil)`; held at `:775`,
  passed **per task** at `:973` (`session.data(for:delegate:)`).
- **The delegate is on every network call, because there is exactly one.**
  Grepping the whole file for `session.`, `dataTask`, `.data(`, `.bytes(`,
  `.upload(`, `.download(` yields a single call site — `:973`. All three entry
  points funnel through the one `send` at `:966` (`_clean` `:835`, `_command`
  `:890`, `testConnection` `:937`). There is no second path to miss.
- **No injected session bypasses it.** The delegate rides the *call*, not the
  session, so any injected `URLSession` is covered by construction. Production
  never injects one: `PostProcessStage.swift:26`, `AppState.swift:440`, and
  `PostProcessSettingsTab.swift:18` all use `PostProcessService()`. Only tests
  pass a session. `data(for:delegate:)` needs macOS 12+; the package targets
  `.macOS(.v13)` (`Package.swift:9`).
- **Independent probe** (standalone Swift, two loopback listeners, a session
  configured exactly like production, run outside the test suite): *without*
  the delegate a `307` and a `308` re-POST the complete body — a unique marker
  string was observed arriving at the redirect target. *With* the delegate the
  target received **zero** connections for `301`, `302`, `307`, and `308`, and
  the 3xx came back as the response with no error. So the prior reviewer's
  exfiltration is confirmed real, and the fix closes it across all four codes —
  including `301`/`302`, which do not carry the body but did leak liveness,
  headers, and the URL.

The `(300...399)` → `.httpStatus` conversion at `:989-991` is **defense in
depth, not load-bearing**: all three consumers already reject anything outside
`200...299` (`:456`, `:615`, `:941`) and produce the identical
`.httpStatus(code)`. Harmless, and it introduces no regression for any existing
caller or test.

#### The 307 test is rigorous, not decorative

`testARedirectFromTheConfiguredEndpointIsNeverFollowed` binds **two real
sockets** on distinct ephemeral loopback ports, drives the real production
`URLSession`, and asserts `target.requests.isEmpty` — zero bytes at the
redirect target. Critically, it also asserts that the *redirector* received the
request **and that the transcript body was in it**, which is what stops the
zero-bytes assertion from passing vacuously had the helper failed to bind or
its accept thread died. Run 5× in isolation: stable, 0 failures.

#### The other four items

| Item | Status | Evidence |
| --- | --- | --- |
| MEDIUM-2 — UI copy matches enforcement | Closed | `PostProcessSettingsTab.swift:58` states the refusal, the degrade-to-raw consequence, and an actionable remedy; doc comment `:20-23` no longer claims "a warning rather than a hard block" |
| MEDIUM-3 — accept side covers all three entry points | Closed | `testLoopbackEndpointsReachTheTransport` drives `clean`→`command`→`testConnection` asserting 1→2→3 for each of four loopback hosts; inverting any one guard fails it |
| MINOR-5 — trim dropped | Closed | Predicate matches verbatim (`:181-199`); `"localhost "` and `" 127.0.0.1"` are explicit reject cases |
| MINOR-4 — correct filter recorded | Closed | Recorded in Change Log and Debug Log; see NIT-12 on the count |

#### Predicate re-probed in the dangerous direction

Independently ran the shipped predicate over 25 host spellings and resolved
each accepted one through `getaddrinfo`. **Every accepted host resolves to a
loopback address; zero accepted-but-off-box cases.** `127.000.000.001` and
`127.0.0.0000000001` are accepted and do resolve to `127.0.0.1`;
`127.0.0.256`, `1270.0.0.1`, `128.0.0.1`, `126.255.255.255`, `127.1`,
`0177.0.0.1`, `2130706433`, `0.0.0.0`, `127..0.1`, and the trailing-dot forms
are all refused. Fail-closed throughout.

#### Test runs

- `swift test --filter "PostProcessRequestBuilderTests|PostProcessServiceTransportTests"`
  → **25 tests, 0 failures.**
- `swift test` → **796 tests, 1 skipped, 0 failures**, exit 0.

#### Non-blocking findings (new; none gate this story)

**NEW-LOW-9 — redirects are refused even loopback→loopback.** Returning `nil`
unconditionally also refuses a *local* redirect, e.g. a loopback reverse proxy
that `301`s for path normalization in front of the LLM. That configuration
would now hard-fail into a silent degrade-to-raw. Diagnosable — Test Connection
reports `HTTP 301` — and the prior review explicitly sanctioned `nil` as an
acceptable fix, so this is a deliberate fail-closed trade, not a defect.
Re-running `isLoopback` on `newRequest.url` would preserve legitimate local
redirects if this ever bites a real user.

**NEW-LOW-10 — `StubHTTPListener` can leak its accept thread (test-only).**
`deinit` calls `close(fd)` while a detached thread is blocked in `accept()`. On
macOS, closing a descriptor does not reliably wake a blocked `accept()`, so the
thread can outlive the listener and — if the descriptor number is recycled —
could in principle accept a later connection. No flakiness observed over 5
isolated runs plus the full suite, and the pre-existing never-replying-socket
helper in the same file uses the same pattern, so this is consistent with
existing style rather than a new sin.

**NIT-11 — doc drift in the line numbers cited above.** The Remediation section
cites `isLoopback` at `:177-182` (actual `:181-199`) and `RedirectBlocker` at
`:753-766` (actual `:753-765`). Cosmetic.

**NIT-12 — the Debug Log says "26 tests" for the two-class filter; the actual
count is 25** (18 in `PostProcessRequestBuilderTests`, 7 in
`PostProcessServiceTransportTests`). Cosmetic.

LOW-6, LOW-7, and LOW-8 from the first pass remain open by design — all
fail-closed or pre-existing, and none was in scope for this remediation.

#### Story goal

The threat statement — "a mistyped or **malicious** endpoint can never
exfiltrate what I dictate" — now holds for the paths this story owns. The
loopback guard covers all three entry points, the single transport call refuses
every redirect, and `PostProcessService` is the only sender of transcript data
in `Sources/` (the sole other `URLSession` user, `UpdateChecker.swift`, is
deliberately internet-facing and carries no transcript). NFR-1 claim stands.

---

**Validation: PASSED 2026-08-22** — ACs are concrete (named hosts to accept/
reject, "zero requests issued" is directly assertable against the existing
mock transport/listener) and self-contained (exact call sites in
`PostProcessService`, the existing error case to reuse, the existing test
helper to build on). Task 1's UI-reuse suggestion is explicitly marked
optional so it can't block AC completion. No fixes needed.

<!-- checkpoint: epic-9 closed 2026-08-22 — story done, code-review approved, suite 796 green, committed with re-verification round -->
