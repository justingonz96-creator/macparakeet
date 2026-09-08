# MacParakeet 0.8.0 release verification

Status: **IN PROGRESS — no release-readiness verdict yet.** The single full Swift suite passed; the distribution build is running. Final-bundle GUI, hardware/TCC, notarization and main merge remain open.

## Scope and provenance

- Requested: review changes since stable, exercise real GUI/CLI workflows with public or synthetic audio, fix concrete blockers, and retain reusable methodology and evidence.
- Stable baseline: `v0.7.3`, commit `d6321f87dccecf29bd4792113f522bb0c98d1f35`.
- Initial main and currently exercised GUI baseline: `8548c099af5ee2ab0ed4dd9efe757d85c498cca0`.
- Committed product fixes: `96b2025253ad71d01566713560ea7d101a13c53d`. Documentation-only HEAD: `b7dfbb680d1d73a0ac0ca11b307e678ca93151f2`.
- Owning branch: `release/0.8.0-qa`, dedicated checkout based on freshly fetched main. Unrelated dirty checkouts and user data are preserved.
- GUI evidence uses the copied Xcode Release baseline product, bundle `com.macparakeet.qa.release080`, displayed version `0.8.0`, observed PID `98237`. Its version label does not make it the final distribution artifact.
- Distribution build is now running from `b7dfbb68` with `VERSION=0.8.0` and `REQUIRE_MEETING_ECHO_ASSETS=1`. Embedded CLI target is independently `3.3.0`.

## Evidence standard and method

Each check in [the dashboard](index.html) and [editable evidence](evidence.json) records its actual candidate, expected/observed behavior, result and limits. Historical RED and later GREEN remain separate. An unverified combination does not inherit a pass from another engine, build or test family.

1. Inventory stable-to-candidate changes and map them to workflows, contracts and failure paths.
2. Review audio, CLI/data, package and UI source independently while root owns desktop actions and all product builds/tests.
3. Verify disposable paths before destructive QA. A development bundle ID alone does not isolate the database, named preferences or Keychain.
4. Exercise real UI and CLI paths, then assert persisted database records, retained audio, clipboard/export content or validator results.
5. Use deterministic regressions before narrow fixes. Run focused families during iteration; reserve exactly one full suite for settled product source.
6. Inspect the final rebuilt artifact and repeat relevant GUI checks before reaching a release decision.

Committed media contains only individually inspected app-window screenshots and synthetic/public fixture content. Raw AX trees, file panels, private data, audio and unabridged local logs stay outside the report. The GUI evidence manifest records hashes and rejected captures; a successful screenshot command or filename is not proof of its contents.

## Current observed results

- **Full suite:** the one invocation exited 0 on product `96b20252` with documentation HEAD `b7dfbb68`; no product source changed during the run. XCTest: **5,461 tests, 20 skips, zero failures, 214.046 seconds**. Swift Testing: **29 tests, zero failures**. [Summary, skip reasons and full-log hash](evidence/full-swift-test-summary.log); raw log `/tmp/macparakeet-080-qa/evidence/full-swift-test.log`. Skipped hardware/conditional cases remain limitations.
- **Formatting:** five changed Swift files introduced zero new diagnostics relative to the base. [Comparison](evidence/format-comparison-final.json).
- **Recovery:** initial stale-owner discard RED: two tests/eight failures; first GREEN: 85 tests. Partial-deletion RED: one test/three failures; GREEN: 87 tests. Cleanup-mutex RED: one test/two failures; final GREEN: **88 tests**. The final repair restores missing markers without overwriting present ownership and independently attempts lease release after restoration failure.
- **Timed cache:** record-replacement RED: two tests/six assertions; after ID scoping, **23 cache/layout/action tests passed**. These are deterministic/offscreen checks; baseline GUI screenshots do not verify the new fix.
- **Baseline GUI:** vocabulary counts progressed **1025 → 1023 → 926 → 0**, with cancellation preservation and one untouched snippet. Track chooser cancellation left no row; English selection persisted ordinal 0. Real editing preserved raw text and saved clean text/Edited state. Grid/list switching rendered. Actual GUI DAPT output passed BBC validation after creating the missing owned Downloads directory.
- **File audio:** six real CLI cases and **29 assertions passed** across embedded tracks, invalid-track rejection and automatic/exact-count diarization. Both speaker runs retain a boundary attribution mismatch; runtime success is not an accuracy certification.
- **Microphone:** Test Input detected input and stopped automatically. Two microphone-only meetings retained audio with healthy coverage and no settlement locks. First: 48.9 seconds at speaker volume 13, no transcript; second: 13.5 seconds at temporary volume 50, 116 recognized public-speech characters. Volume was restored to 13. The first input-level failure is retained rather than counted as a recognition pass.
- **Quiet options:** both completion options were visibly off. The app was already frontmost; preserving another app's focus remains unverified.
- **Package preflight:** all **24 commands** met their expected outcomes on scripts and synthetic fixtures. This does not certify the actual app/DMG, signing, real echo assets or notarization.

Focused raw/curated evidence:

- [Initial recovery RED](evidence/recovery-discard-red.log), [first recovery GREEN / cache RED](evidence/cache-red-recovery-green.log), [cache GREEN](evidence/cache-green.log).
- [Partial-deletion RED](evidence/recovery-partial-delete-red.log), [87-test GREEN](evidence/recovery-partial-delete-green.log).
- [Mutex-release RED](evidence/recovery-mutex-release-red.log), [88-test GREEN](evidence/recovery-mutex-release-green.log).
- [Microphone result fields](evidence/mic-meetings-results.json), raw capture observations under `/tmp/macparakeet-080-qa/evidence/`.

## Reports

- [Release change inventory](release-inventory.md)
- [Audio and recovery source review](audio-review.md)
- [CLI, data and inference source review](cli-data-review.md)
- [Markdown and transcript source review](ui-source-review.md)
- [Executed CLI contracts](cli-runtime.md) and [DAPT/export matrix](dapt-runtime.md)
- [Engine/language samples](audio-runtime.md) and [file tracks / diarization](file-audio-runtime.md)
- [Completed baseline GUI scenarios](gui-runtime.md)
- [Microphone runtime and authorization limits](microphone-runtime.md)
- [Package preflight and remaining artifact checks](package-preflight.md)
- [Reusable GUI fixtures](gui-fixtures.md)
- [Initial setup and historical runtime log](runtime-log.md)

## What worked and what did not

- `CFFIXED_USER_HOME` redirected Foundation home/Application Support paths, verified with a resolver probe and the actual open SQLite path. It did not isolate named UserDefaults suites. A unique bundle ID separated ordinary GUI preferences; fixed Keychain services and shared CLI preferences required separate treatment. The uniquely named preference probe domain was removed.
- Bundled `@oai/sky` refused this host because it required its trusted nodeRepl runtime. No guard was bypassed. Native AppKit/ApplicationServices inspection, AX actions, focused key events and window captures supported the GUI pass.
- Earlier desktop work paused while the user used the computer, then resumed when available. That pause is historical, not the current release status. Direct AX value-setting and PID-targeted events did not consistently update SwiftUI bindings; verified focus and active-session input plus SQLite receipts established actual saves.
- A low speaker level produced healthy captured frames but no recognized text. Increasing only the owned replay's volume yielded a recognized sentence, then the original volume was restored. This supports inadequate fixture audibility without ruling out every empty-transcript cause.
- A missing fake-home Downloads directory initially prevented export. A 4×4 screenshot and an ineffective early edit screenshot were excluded. Later file validation and inspected captures supplied actual evidence.
- Saved fixtures are insert-only and source-matched, but they do not prove streaming, forced asynchronous ordering, playback or capture. The inherited stale Library `derivedSnippet` after editing remains a documented follow-up.

## Remaining gates

The final distribution bundle needs exact binary/version/resource/AEC/signature checks and relevant GUI re-verification. macOS Accessibility setup for the unique QA app reached a Touch ID/password authorization sheet; user authentication was requested, without requesting a password in chat or editing TCC. System-audio permission/capture, Bluetooth and other device transitions, pause/mute, global hotkeys, and quiet completion while another app owns focus remain open. Notarization/distribution acceptance and main merge are separate unfinished steps. Passing tests or merging code alone does not establish a release-ready deliverable.
