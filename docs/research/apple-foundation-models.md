# Apple Foundation Models — On-Device LLM Evaluation

> Status: **ACTIVE** · Last verified 2026-05-03

Reference for integrating Apple's `FoundationModels` framework as an LLM provider
in MacParakeet. Captures what we verified about the framework, its constraints,
and how it slots into our existing provider abstraction
(`Sources/MacParakeetCore/Models/LLMProvider.swift`).

## TL;DR

- **Real, shipping, production-ready.** GA'd with macOS Tahoe 26 (fall 2025);
  ~7 months in field by May 2026.
- **Free, on-device, ANE-accelerated.** No API key, no billing, no model bundle
  managed by us. ADR-002 (local-first) preserved.
- **One headline constraint: 4096-token context window, fixed.** Apple has
  stated this will not grow. A 30-minute meeting transcript overflows.
- **Best fit:** dictation cleanup, short Live Ask exchanges, friction-free
  onboarding for users who already have Apple Intelligence enabled.
- **Worst fit:** full-transcript multi-summary, long-meeting Q&A. These should
  fall back to a cloud provider when the budget is exceeded.
- **Position it as the zero-config starter, not the universal default.** Cloud
  providers remain the upgrade path for long-context workloads.

## State of play (May 2026)

| Item | Detail |
|---|---|
| Framework | `import FoundationModels` |
| GA platform | macOS Tahoe 26.0 (fall 2025) |
| Current line | macOS 26.4 (added context-window introspection APIs) |
| Model | ~3B parameter on-device LLM with 5:3-depth two-block architecture and shared KV cache (Apple ML Research, 2025) |
| Streaming | Yes (`streamResponse`) |
| Tool calling | Yes (`Tool` protocol) |
| Structured output | Yes (`@Generable` macro) |
| Languages | 15: EN, DA, NL, FR, DE, IT, NO, PT, ES, SV, TR, ZH-Hans, ZH-Hant, JA, KO, VI |
| Regions | Widely available; **excluded on devices purchased in mainland China or with Apple Account set to mainland China** |
| Apple's quality claim | Competitive with Qwen-2.5-3B, Qwen-3-4B, Gemma-3-4B on the on-device benchmark |
| Real-world quality | Below frontier cloud models for complex reasoning; fine for dictation cleanup, summarization of short text, simple Q&A |

## Hardware, OS, and user requirements

A user can run `LanguageModelSession` if and only if **all** of these are true:

1. **Apple Silicon Mac.** M1 or newer.
2. **macOS Tahoe 26.0+.** (Our deployment target stays at macOS 14.2; the
   Apple FM tile is gated on `@available(macOS 26.0, *)` + runtime
   availability check. Older-OS users see no option.)
3. **8 GB RAM minimum**, 16 GB strongly recommended for comfortable use.
4. **Apple Intelligence enabled** in System Settings → Apple Intelligence & Siri.
   This is a **one-time, OS-level** ~3–7 GB download. **MacParakeet ships no
   weights and manages no download UI** — the OS handles it.
5. **Region not mainland-China-purchased.**

The download is shared system-wide. Once any app (or the OS) has triggered the
enable flow, every other app calling `FoundationModels` gets the same model
with no further setup.

## The 4096-token context wall

This is the constraint that shapes integration:

- **Hard ceiling: 4096 tokens** for the entire session (instructions + all
  prompts + all responses combined).
- **Apple has stated this is fixed**, not "current". Don't design around it
  growing.
- Overflow throws **`.exceededContextWindowSize`**; the session is dead and
  cannot recover within the same instance.
- **macOS 26.4 added introspection** (`@backDeployed(before: macOS 26.4)`):
  - `SystemLanguageModel.contextSize` — capacity for the current model
  - `SystemLanguageModel.tokenCount(for:)` — measure a prompt before sending

### What that means for MacParakeet's LLM workloads

| Workload | Typical token cost | Apple FM verdict |
|---|---|---|
| AI dictation formatter (clean a paragraph) | ~50–500 | **Excellent.** Always fits. |
| Live Ask tab (recent transcript window + question) | ~500–2000 | **Good.** Fits most exchanges. |
| Multi-summary on full transcript | 30-min meeting ≈ 4000–5000; podcast ≈ 10–20k | **Overflows most real content.** |
| Prompt Library / chat over full transcript | Same | **Overflows most real content.** |

Quick rule of thumb: **~1 minute of speech ≈ 150 tokens**. A 27-minute
transcript already touches the wall before adding instructions, prompt, or
response budget.

### Recommended overflow pattern

Don't silently chunk-and-stitch in v1 — quality drops and it hides the limit
from users. Instead:

1. Call `SystemLanguageModel.tokenCount(for:)` with the full prompt before
   creating the session.
2. If under budget → use Apple FM.
3. If over budget AND user has a configured cloud provider → fall back to that
   provider automatically with a one-time inline notice ("Long transcript —
   used [Cloud Provider]").
4. If over budget AND no cloud provider configured → surface "Transcript too
   long for the on-device model. Add a provider in Settings, or use a shorter
   prompt."

## API surface

All of the below requires `import FoundationModels` and is gated by
`@available(macOS 26.0, *)`.

### Availability check

```swift
import FoundationModels

let model = SystemLanguageModel.default

switch model.availability {
case .available:
    // Ready to use.
case .unavailable(let reason):
    switch reason {
    case .deviceNotEligible:
        // Permanent — Intel Mac, old M1 without enough RAM, China-purchased, etc.
        // Hide the tile or show "not supported on this Mac."
    case .appleIntelligenceNotEnabled:
        // User must enable in System Settings. Deep-link them.
    case .modelNotReady:
        // Model is still downloading. Retry later; offer a refresh.
    @unknown default:
        // Future reasons — treat as unavailable.
    }
}
```

These three reasons are **three different UX problems**. Don't collapse them.

### Session with instructions

```swift
let session = LanguageModelSession {
    """
    You are a transcription assistant. Given a meeting transcript,
    answer the user's question concisely using only the provided context.
    """
}
```

Sessions hold their own conversation history — instructions + every prompt and
response counts against the 4096-token budget. **For the Live Ask tab, prefer
short-lived sessions per question** rather than one long-running session, to
avoid blowing the budget mid-conversation.

### One-shot generation

```swift
let response = try await session.respond(to: prompt)
print(response.content)
```

`response.content` is a `String` (or generated type if using `@Generable`).

### Streaming generation

```swift
let stream = session.streamResponse(to: prompt)
for try await partial in stream {
    // partial is the cumulative response so far — render it directly.
    updateUI(with: partial)
}
```

This is what we'd wire into the Live Ask streaming UI (ADR-018) and the AI
dictation formatter when it shows live results.

### Structured output (`@Generable`)

```swift
@Generable
struct DictationCleanup {
    let cleaned: String
    let detectedLanguage: String
}

let result = try await session.respond(
    to: rawDictationText,
    generating: DictationCleanup.self
)
print(result.content.cleaned)
```

Skip for v1 — text output parsed downstream is faster to ship and matches how
existing providers work in `LLMService`.

### Tool calling (`Tool` protocol)

```swift
final class FetchTranscriptTool: Tool {
    let name = "fetchTranscript"
    let description = "Returns the meeting transcript by ID."

    @Generable
    struct Arguments {
        let meetingID: String
    }

    func call(arguments: Arguments) async throws -> ToolOutput {
        let text = try await TranscriptionRepository.shared.text(for: arguments.meetingID)
        return ToolOutput(text)
    }
}
```

Tools aren't required for our v1 use cases. Worth revisiting if we ever expose
the LLM as an "agent" surface that can search transcripts.

## Privacy posture

- `LanguageModelSession` runs the **on-device** ~3B model on the Neural Engine.
- It does **not** route to Private Cloud Compute. PCC is a separate Apple
  Intelligence path used by Siri / Writing Tools / Image Playground, not the
  developer framework.
- ADR-002 (local-first) is preserved without caveat.
- No user data leaves the device for any `respond` / `streamResponse` call.

This is identical to our existing `Ollama` / `LM Studio` / `Local CLI`
providers from a privacy standpoint, with the added benefits that the model is
managed by the OS and runs on the ANE rather than CPU/GPU.

## Entitlements

- **Base usage** of `SystemLanguageModel` and `LanguageModelSession`: **no
  entitlement required.** Just import and use.
- **Custom adapters** (training a fine-tuned adapter on top of the base model
  and shipping it): requires `com.apple.developer.foundation-model-adapter`.
  Account holder must request it in Apple Developer. **We do not need this.**

## How the user-side download works

| User state | What MacParakeet does | What the user sees |
|---|---|---|
| Apple Intelligence already enabled | Calls `availability`, gets `.available`, model is ready | Nothing — it just works |
| Compatible Mac, AI not enabled | Tile shows "Enable Apple Intelligence in System Settings" with a deep link (`x-apple.systempreferences:com.apple.preference.appleintelligence`) | One settings flip, OS downloads model in background |
| Compatible Mac, model still downloading | `availability == .unavailable(.modelNotReady)` — show "Apple Intelligence is downloading. Try again in a few minutes." | Wait, then retry |
| Intel Mac / 8 GB Mac with insufficient resources / pre-26 macOS | `availability == .unavailable(.deviceNotEligible)` — hide the tile | No option shown |
| China-purchased device | Same as above | No option shown |

**The download is OS-level and shared.** We don't bundle weights, manage
download progress, or version-pin the model. The OS pushes updates as part of
macOS point releases. This is meaningfully better friction than our
Parakeet-CoreML (~465 MB fetched components per selected build in current
MacParakeet usage) or WhisperKit model paths.

## Where it fits in MacParakeet

### Provider model

`Sources/MacParakeetCore/Models/LLMProvider.swift:5` defines `LLMProviderID`.
Add a case:

```swift
case appleFoundation  // displayName: "Apple Intelligence"
```

Properties: `requiresAPIKey = false`, `isLocal = true`,
`supportsCustomBaseURL = false`, `supportsModelSelection = false`.

### Implementation

New file: `Sources/MacParakeetCore/Services/AppleFoundationLLMClient.swift`,
conforming to `LLMClient`. The non-streaming path wraps `respond(to:)`; the
streaming path wraps `streamResponse(to:)`. Both must handle:

- Availability re-check on every call (the user can disable Apple Intelligence
  at any time).
- `LanguageModelSession.GenerationError.exceededContextWindowSize` →
  surface as `LLMError.contextTooLong` so `RoutingLLMClient` can fall back.
- Token-budget pre-check via `SystemLanguageModel.tokenCount(for:)` for prompts
  that include full transcripts.

All `FoundationModels` symbols must be gated:

```swift
@available(macOS 26.0, *)
final class AppleFoundationLLMClient: LLMClient { ... }
```

The provider registration in `RoutingLLMClient` checks the runtime macOS
version before instantiating.

### Onboarding (ADR-005)

In the LLM provider step:

1. Check `SystemLanguageModel.default.availability` if running macOS 26+.
2. If `.available` AND no provider is configured yet → set `appleFoundation`
   as the default. Skip the API-key step entirely.
3. If `.unavailable(.appleIntelligenceNotEnabled)` → offer a "Enable Apple
   Intelligence (free)" CTA with the deep link, plus the existing manual
   provider flow.
4. Otherwise → existing flow.

**Never overwrite a provider the user has already configured.** This is for
new onboardings only.

### Settings tile

`Sources/MacParakeet/Views/Settings/LLMSettingsView.swift` — a tile that:

- Shows the current `availability` state with a clear status pill.
- For `.appleIntelligenceNotEnabled`, links to System Settings.
- For `.modelNotReady`, shows a refresh button.
- For `.deviceNotEligible`, hides the tile entirely (no point reminding the
  user their hardware can't do this).
- Does **not** show an API key field (there isn't one).
- Subtitle: "Free, on-device, best for short prompts."

### Wired into the four call sites

1. **AI dictation formatter** (`#100`) — perfect fit, ship as default when
   Apple FM is the configured provider.
2. **Live Ask tab** (ADR-018) — short-lived per-question sessions; `respond` /
   `streamResponse` directly.
3. **Prompt Library single-prompt run** (ADR-013) — token-budget check; fall
   back to user's cloud provider on overflow.
4. **Multi-summary** — same. Most of these will overflow Apple FM in practice;
   that's fine — they'll fall back to cloud.

### Telemetry

Per `feedback_telemetry_allowlist.md`: adding `llm_provider_appleFoundation`
to `TelemetryEventName` requires a paired commit on
`macparakeet-website/functions/api/telemetry.ts` adding it to
`ALLOWED_EVENTS`. Without that, the Worker drops the entire batch. Deploy the
website change **before** merging the Swift change.

## Sizing

- Provider plumbing + Settings tile + onboarding wiring: **1–2 days.**
- Token-budget guard with cloud fallback for long prompts: **+1 day.**
- Total: **~2–3 days** for a polished v1.

## Risks & open questions

| Risk | Mitigation |
|---|---|
| **macOS 26 adoption skew** — some MacParakeet users are on 14.x/15.x and won't see the option | Graceful: existing providers remain primary; Apple FM is additive. |
| **8 GB Macs may report `.available` but perform poorly** | Apple's reason cases don't distinguish "available but slow." Accept this; users who notice can switch providers. |
| **4096-token ceiling pushes power users back to cloud anyway** | Reframe: this is the *zero-config starter*, cloud is the upgrade path. The funnel is healthier for it. |
| **China-purchased devices excluded** | Surface gracefully via `.deviceNotEligible`. Don't hardcode region checks. |
| **Quality below frontier cloud models for complex reasoning** | Fine for dictation cleanup and short Q&A; long-form summary already routes to cloud per overflow handling. |
| **Sessions accumulate context within one instance** | Use short-lived sessions per Live Ask question, not one long-running session. |
| **Model versions move with macOS point releases** | We can't pin a version. Smoke-test prompt outputs after each macOS update; treat behavior changes as a regression class. |
| **`tokenCount(for:)` only available on macOS 26.4+** | `@backDeployed` covers older 26.x. For pre-26 we never reach this code path. |

## Open follow-ups

- [ ] Verify exact `LLMError.contextTooLong` mapping with a 5000-token test
      prompt against a real device.
- [ ] Decide whether to expose Apple FM in CLI (`macparakeet-cli`). The CLI is
      a public contract — if we add it there, it becomes a downstream
      compatibility concern. Defer until GUI ships.
- [ ] Measure first-call warm-up latency. If >1.5s, prefetch with an empty
      `respond` when the Live Ask tab opens.

## References

### Apple official
- [Foundation Models — Apple Developer Docs](https://developer.apple.com/documentation/FoundationModels)
- [Generating content and performing tasks with Foundation Models](https://developer.apple.com/documentation/FoundationModels/generating-content-and-performing-tasks-with-foundation-models)
- [TN3193: Managing the on-device foundation model's context window](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window)
- [WWDC25 — Meet the Foundation Models framework (286)](https://developer.apple.com/videos/play/wwdc2025/286/)
- [WWDC25 — Deep dive into the Foundation Models framework (301)](https://developer.apple.com/videos/play/wwdc2025/301/)
- [Updates to Apple's On-Device and Server Foundation Language Models — Apple ML Research](https://machinelearning.apple.com/research/apple-foundation-models-2025-updates)
- [How to get Apple Intelligence — Apple Support (regions & languages)](https://support.apple.com/en-us/121115)
- [com.apple.developer.foundation-model-adapter entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.foundation-model-adapter)

### Third-party deep-dives
- [InfoQ — Apple Improves Context Window Management (Mar 2026)](https://www.infoq.com/news/2026/03/apple-foundation-models-context/)
- [Artem Novichkov — Getting Started with Apple's Foundation Models](https://artemnovichkov.com/blog/getting-started-with-apple-foundation-models)
- [Create with Swift — Exploring the Foundation Models framework](https://www.createwithswift.com/exploring-the-foundation-models-framework/)
- [Natasha the Robot — Introduction to Apple's FoundationModels](https://www.natashatherobot.com/p/apple-foundation-models)
- [DEV Community — Falling back gracefully when Apple Intelligence isn't available](https://dev.to/arshtechpro/how-to-fall-back-gracefully-when-apple-intelligence-isnt-available-48j)
