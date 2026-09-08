# Echo Accuracy & Utility Upgrade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Echo's fitness-class transcripts and SRT/VTT captions measurably more accurate, and make producing them faster (batch folders, Echelon vocabulary, a locked caption preset), without losing any of the fork's custom caption work.

**Architecture:** Measure first (a small private Echelon benchmark scored with the upstream WER harness), then land the cheap Whisper fixes that need no merge, then perform the one big upstream sync (852 commits, 46 conflicting files as of 2026-09-08) that brings Parakeet Unified, Cohere Transcribe, vocabulary boosting, batch CLI, and diarization fixes. Finally choose the caption engine from the benchmark numbers, not from vendor claims, and add the utility layer on top.

**Tech Stack:** Swift 6 / SwiftPM (Xcode 26.6), WhisperKit via `argmax-oss-swift` 1.0.0 (fork) / 0.18.0 (upstream pin, to be resolved in favour of the fork), FluidAudio 0.14.5 → 0.15.6, GRDB, Python 3 + `jiwer` + `whisper-normalizer` for scoring, `macparakeet-cli` for headless runs.

**Spec:** This document's "Findings & decisions" section below is the spec. There is no separate design doc; the review that produced it lives in the Claude session of 2026-09-08 and is summarised here so the plan travels with its rationale.

## Global Constraints

- Apple Silicon only, macOS 14.2+ runtime floor; Justin's machine: M5 Max, 64 GB, macOS 26.6.
- All speech recognition stays on-device (ADR-002). No cloud STT.
- Never commit Echelon class audio, clips, or reference transcripts. `benchmarks/echelon/clips/` and `benchmarks/echelon/refs/` are git-ignored.
- Never work on `main` directly. Every phase starts from a branch off `main` with a save-point commit; `main` only moves by fast-forward merge after the phase's gate passes.
- The uncommitted working-tree edits present on 2026-09-08 (7 files: `TransformsCommand.swift`, `DictationOverlayView.swift`, `FlowerCompletionView.swift`, `CalendarService.swift`, `ExportService.swift`, `LayoutPlanParser.swift`, `LLMSettingsDraft.swift`) are trivial lint cleanups. Task 1 commits them so the tree is clean before anything else.
- `swift test` (full suite, ~100 s, 3,255 test functions) must pass before any phase gate. Focused filters are for iteration only.
- Fork-only features that MUST survive the sync: `SubtitleExportConfig` presets + `enforceMinDuration`/`enforceMinGap`, `WordNumberSplitter`, `NumberLLMRefiner` + `NumberRefinementMode`, `SubtitleLLMLayoutPlanner`/`SubtitleLLMReviewer`/`ModelProfileService`, `WhisperTuningPreset`, `applyPeriodCountdownAtCueStartPass`, the Echo rebrand (bundle id `com.echelonfit.echo`, DesignSystem palette, icon), `scripts/dev/install_local.sh`.
- Keep WhisperKit at the fork's `argmax-oss-swift` 1.0.0 (upstream is on 0.18.0). Do not downgrade during the merge.
- Success metric: word error rate (WER) on the Echelon fixture, scored by `benchmarks/asr/score.py` with the Whisper English normalizer. Report every engine claim with that number.

---

## Findings & decisions (the spec)

**Where Echo is.** Echo = fork of `moona3k/macparakeet`, last synced 2026-05-24 (merge-base `d42138a0`). Upstream is at v0.7.3 with 0.8.0 QA complete. Current Echo settings (from `defaults read com.echelonfit.echo`): engine `whisper` (large-v3-turbo), tuning preset `cleanStudio`, no Whisper language pinned (auto-detect each window), LLM caption refinement on via Ollama `gemma4:31b-cloud`, subtitle config `{maxCharsPerLine:65, maxLinesPerCue:2, maxDurationMs:4000, maxCPS:17, endTimeBufferMs:1000, snapToFrameRate:29.97, minWordsBeforePunctuationBreak:4, reviewerPairsPerBatch:5, normalizeNumbers:false}`, `numberRefinementMode: smart`.

**Accuracy evidence (upstream `benchmarks/asr/README.md`, LibriSpeech full sets, M4 Pro).**

| Engine | macro WER | noisy `test-other` | word timestamps | RAM |
|---|---:|---:|---|---:|
| Cohere Transcribe q8 | 2.07% | 2.65% | **no** | ~11.6 GB |
| Parakeet Unified (EN) | 2.38% | 3.13% | yes (token-derived) | 115 MB |
| Parakeet v2 (EN) | 2.57% | 3.27% | yes | 123 MB |
| Whisper large-v3-turbo (current) | 3.00% | 4.04% | yes | 274 MB |
| Parakeet v3 (multilingual) | 3.22% | 4.14% | yes | 131 MB |
| Nemotron EN / multi | 3.70% / 5.17% | 5.01% / 7.16% | yes | ~140 MB |

**Decision 1 — captions need word timestamps, so Cohere is not the caption engine.** Cohere's capability entry is `providesWordTimestamps: false`; transcripts "degrade to plain text". It is still worth measuring as a *text-only* reference and as a future hybrid (Cohere words + Parakeet timings), but that hybrid is out of scope here. **Parakeet Unified is the target caption engine**: best English accuracy that keeps word timing, adds native punctuation/capitalisation, ~5× faster than Whisper, and does not hallucinate through music the way an autoregressive Whisper decoder can.

**Decision 2 — fix Whisper first anyway.** Even after the switch, Whisper stays the fallback for non-English classes and for A/B comparison. Two defects in `WhisperEngine.makeDecodingOptions` are cheap: no `chunkingStrategy` (WhisperKit default cuts every 30 s regardless of speech → split/repeated words at seams; `.vad` cuts at silence), and no `promptTokens` (Whisper accepts an initial glossary prompt that steers spelling of names/products). Pinning the language to English is a Settings change, not code.

**Decision 3 — measure on Echelon audio.** LibriSpeech is read speech; classes have music, breathing, shouted cues, countdowns. A five-clip private fixture with hand-corrected references, scored with the upstream harness, is the gate for every engine claim in this plan.

**Decision 4 — do the upstream sync as one dedicated phase.** Trial merge on 2026-09-08: 46 conflicting files, ~180 conflict hunks (77 in `TranscriptResultView.swift`, 20 in `ExportService.swift`, 7 in `TranscriptionService.swift`, the rest ≤5). Upstream renormalised line endings to LF (`f858bc87`), so merge with `-X ignore-space-at-eol`. Incoming: 1,383 files, +322k/−23k lines. Gains beyond engines: custom-vocabulary CTC boosting (`CustomVocabularyBoosting.swift`), capability registry, dropped-final-word fixes (#562, #632), high-accuracy diarization + attendee prior (#974), batch CLI (`transcribe` accepts folders, `--output-dir`, `--format srt|vtt|dapt`, `--parakeet-model unified`), library bulk export (#661), W3C DAPT export (#854), Retranscribe with engine choice (#637). Upstream did NOT merge the fork's PRs #305/#307/#308, so the subtitle work is fork-only and will conflict in `ExportService.swift`.

**Decision 5 — utility scope.** (a) Batch-caption a folder of class videos to SRT in one command. (b) An "Echelon" caption preset that pins today's tuned values so nobody has to re-enter them. (c) Seed Echelon vocabulary (instructor names, product terms, class cues) once, used by Whisper prompt now and Parakeet CTC boosting after the sync. Everything else upstream ships (meetings, dictation, knowledge layer) comes along but is not tuned here.

**Explicitly not doing.** Nemotron (dominated). Apple SpeechTranscriber (no benchmarks, macOS 26 only). New Whisper models (none exist). Cohere hybrid alignment (separate plan if Phase 3 shows Cohere's text is meaningfully better on Echelon audio).

---

## Phase 0 — Clean tree and a yardstick

### Task 1: Commit the stray lint edits and open the working branch

**Files:**
- Modify (commit as-is): `Sources/CLI/Commands/TransformsCommand.swift`, `Sources/MacParakeet/Views/Dictation/DictationOverlayView.swift`, `Sources/MacParakeet/Views/MeetingRecording/FlowerCompletionView.swift`, `Sources/MacParakeetCore/Calendar/CalendarService.swift`, `Sources/MacParakeetCore/Services/ExportService.swift`, `Sources/MacParakeetCore/Services/Subtitle/LayoutPlanParser.swift`, `Sources/MacParakeetViewModels/LLMSettingsDraft.swift`
- Modify: `.gitignore` (add `.claire/`)

- [ ] **Step 1: Confirm the edits are only dead-code removals**

Run: `cd /Users/Justin/Documents/Codex/2026-05-14/id-like-to-make-a-copy/macparakeet && git diff --stat && git diff | grep '^[+-][^+-]' | grep -v '^\-\s*$' | head -40`
Expected: 7 files, 7 insertions, 16 deletions; every removed line is an empty `if {}` body, an unused `let _ =`, an `enumerated()` whose index is unused, or an unused import. No behaviour change.

- [ ] **Step 2: Build and run the focused tests for the touched areas**

Run: `swift build 2>&1 | tail -3 && swift test --filter 'ExportService|Subtitle|LayoutPlan|Calendar|LLMSettings' 2>&1 | tail -5`
Expected: build succeeds; tests end with `Executed N tests, with 0 failures`.

- [ ] **Step 3: Ignore the local `.claire/` worktree folder and commit**

```bash
printf '\n# local agent worktrees\n.claire/\n' >> .gitignore
git add -A
git commit -m "chore: remove dead statements flagged by lint; ignore .claire/"
```

- [ ] **Step 4: Tag the save point and create the phase branch**

```bash
git tag echo-pre-upgrade-2026-09-08
git checkout -b upgrade/phase0-yardstick
```

Expected: `git status` clean; `git tag -l 'echo-pre-*'` lists the tag. This tag is the "undo everything" point for the whole plan.

### Task 2: Echelon accuracy fixture + scorer

**Files:**
- Create: `benchmarks/echelon/README.md`
- Create: `benchmarks/echelon/make_clips.sh`
- Create: `benchmarks/echelon/run.sh`
- Create: `benchmarks/echelon/build_records.py`
- Create: `benchmarks/echelon/.gitignore`
- Add from upstream (no conflict, directory does not exist in fork): `benchmarks/asr/score.py`, `benchmarks/asr/test_scorers.py`, `benchmarks/asr/requirements.txt`

**Interfaces:**
- Produces: `benchmarks/echelon/run.sh <engine-label> [extra macparakeet-cli flags...]` → writes `results/<label>.jsonl` (records `{"id","ref","hyp","dataset":"echelon","engine":<label>}`) and prints the `score.py` table. Every later task's "did accuracy improve?" step calls this.

- [ ] **Step 1: Pull the scorer from upstream and set up its Python env**

```bash
git fetch upstream
git checkout upstream/main -- benchmarks/asr/score.py benchmarks/asr/test_scorers.py benchmarks/asr/requirements.txt
python3 -m venv benchmarks/asr/venv
benchmarks/asr/venv/bin/pip install -r benchmarks/asr/requirements.txt
benchmarks/asr/venv/bin/python benchmarks/asr/test_scorers.py
```

Expected: scorer self-tests print `OK`. (`benchmarks/asr/venv/` must be git-ignored; check `git status` shows only the three files as new.)

- [ ] **Step 2: Write the clip cutter**

`benchmarks/echelon/make_clips.sh`:
```bash
#!/usr/bin/env bash
# Cut N two-minute mono 16 kHz excerpts from a class video, spaced evenly,
# so the fixture covers warm-up, work blocks with music, and cool-down.
# Usage: make_clips.sh <class-video> <short-name> [count=5]
set -euo pipefail
SRC="$1"; NAME="$2"; COUNT="${3:-5}"
HERE="$(cd "$(dirname "$0")" && pwd)"
FFMPEG="${FFMPEG:-/Applications/Echo.app/Contents/Resources/ffmpeg}"
mkdir -p "$HERE/clips"
DUR=$("$FFMPEG" -i "$SRC" 2>&1 | sed -n 's/.*Duration: \([0-9]*\):\([0-9]*\):\([0-9]*\).*/\1*3600+\2*60+\3/p' | bc)
STEP=$(( (DUR - 120) / COUNT ))
for i in $(seq 0 $((COUNT-1))); do
  START=$(( 60 + i*STEP ))
  OUT="$HERE/clips/${NAME}-$(printf '%02d' $i).m4a"
  "$FFMPEG" -y -loglevel error -ss "$START" -t 120 -i "$SRC" -vn -ac 1 -ar 16000 -c:a aac -b:a 96k "$OUT"
  echo "wrote $OUT (start ${START}s)"
done
```

- [ ] **Step 3: Write the record builder**

`benchmarks/echelon/build_records.py`:
```python
#!/usr/bin/env python3
"""Pair hypothesis .txt files with reference .txt files into score.py JSONL."""
import json, sys
from pathlib import Path

label, hyp_dir, out = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
refs = Path(__file__).parent / "refs"
n = 0
with out.open("w", encoding="utf-8") as fh:
    for ref in sorted(refs.glob("*.txt")):
        hyp = hyp_dir / ref.name
        if not hyp.exists():
            print(f"WARN missing hypothesis for {ref.name}", file=sys.stderr); continue
        fh.write(json.dumps({"id": ref.stem, "ref": ref.read_text().strip(),
                             "hyp": hyp.read_text().strip(),
                             "dataset": "echelon", "engine": label}, ensure_ascii=False) + "\n")
        n += 1
print(f"{out}: {n} records")
```

- [ ] **Step 4: Write the runner**

`benchmarks/echelon/run.sh`:
```bash
#!/usr/bin/env bash
# Usage: run.sh <label> [macparakeet-cli transcribe flags...]
#   run.sh whisper-baseline --engine whisper
#   run.sh whisper-en       --engine whisper --language en
#   run.sh parakeet-v3      --engine parakeet
# After the upstream sync also: --engine parakeet --parakeet-model unified ; --engine cohere --language en
set -euo pipefail
LABEL="$1"; shift
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CLI="${CLI:-$ROOT/.build/release/macparakeet-cli}"
shopt -s nullglob
CLIPS=("$HERE"/clips/*.m4a)
[ ${#CLIPS[@]} -gt 0 ] || { echo "no clips in $HERE/clips — run make_clips.sh first" >&2; exit 1; }
[ -x "$CLI" ] || (cd "$ROOT" && swift build -c release --product macparakeet-cli)
HYP="$HERE/results/$LABEL"; mkdir -p "$HYP"
START=$(date +%s)
# Flags after "$@" are last-wins in the CLI parser: passing --mode or --format again overrides the pinned values below.
for clip in "${CLIPS[@]}"; do
  base="$(basename "${clip%.m4a}")"
  "$CLI" transcribe "$clip" --format transcript --mode raw --no-history --speaker-detection off "$@" > "$HYP/$base.txt"
done
END=$(date +%s)
echo "wall=$((END-START))s for ${#CLIPS[@]} clips"
python3 "$HERE/build_records.py" "$LABEL" "$HYP" "$HERE/results/$LABEL.jsonl"
"$ROOT/benchmarks/asr/venv/bin/python" "$ROOT/benchmarks/asr/score.py" --ci 1000 "$HERE/results/$LABEL.jsonl"
```

Note `--mode raw`: we score the recogniser, not the text-cleanup pipeline, so cleanup changes cannot mask engine changes. (After the sync, `--speaker-detection off` still exists; keep it.)

- [ ] **Step 5: Git-ignore private material, write the README, make scripts executable**

`benchmarks/echelon/.gitignore`:
```
clips/
refs/
results/
```

`benchmarks/echelon/README.md`:
```markdown
# Echelon accuracy fixture (private audio, scripts only in git)

0. One-time: `python3 -m venv ../asr/venv && ../asr/venv/bin/pip install -r ../asr/requirements.txt` (run from this folder).
1. Pick 1–2 recent class videos. `./make_clips.sh "/path/Class.mp4" marc` cuts five 2-minute
   clips into `clips/`.
2. Produce a first-draft reference for each clip:
   `../../.build/release/macparakeet-cli transcribe clips/marc-00.m4a --format transcript --mode raw --no-history > refs/marc-00.txt`
   then a human corrects every word by ear. **The reference must be what was actually said**,
   including "three, two, one" as words (the scorer's normaliser folds digits and words).
3. `./run.sh <label> <engine flags>` transcribes every clip and prints WER with a 95% CI.
4. Compare labels with `../asr/venv/bin/python ../asr/score.py results/a.jsonl results/b.jsonl`.

Never commit `clips/`, `refs/`, or `results/`.
```

```bash
chmod +x benchmarks/echelon/make_clips.sh benchmarks/echelon/run.sh benchmarks/echelon/build_records.py
```

- [ ] **Step 6: Build the fixture (human step) and record the baseline**

Run `make_clips.sh` on one or two classes (target 5–8 clips, 10–16 minutes of audio). Draft references with the CLI, then hand-correct them (about an hour of listening). Then:

```bash
benchmarks/echelon/run.sh whisper-baseline --engine whisper
benchmarks/echelon/run.sh parakeet-v3 --engine parakeet
```

Expected: two WER numbers with CIs. Paste them into `benchmarks/echelon/README.md` under a "## Baseline 2026-09" heading (numbers only, no transcript text). This is the bar every later task must beat.

- [ ] **Step 7: Commit**

```bash
git add benchmarks/asr/score.py benchmarks/asr/test_scorers.py benchmarks/asr/requirements.txt benchmarks/echelon
git commit -m "bench: add Echelon private accuracy fixture scripts + upstream WER scorer"
```

---

## Phase 1 — Whisper quick wins (no merge required)

### Task 3: Cut Whisper windows at silence (`chunkingStrategy: .vad`)

**Files:**
- Modify: `Sources/MacParakeetCore/STT/WhisperEngine.swift:397-415` (`makeDecodingOptions`)
- Test: `Tests/MacParakeetTests/STT/STTClientTests.swift` (add after `testWhisperDecodeOptionsForAutoLanguageDetectsWithoutPrefillPrompt`)

**Interfaces:**
- Produces: `WhisperEngine.makeDecodingOptions(language:tuning:)` now returns `DecodingOptions` with `chunkingStrategy == .vad`. Signature unchanged.

- [ ] **Step 1: Write the failing test**

```swift
    func testWhisperDecodeOptionsChunkAtSilenceNotFixedWindows() {
        #if canImport(WhisperKit)
        let options = WhisperEngine.makeDecodingOptions(language: "en")
        // WhisperKit's default (.none) slices every 30 s regardless of speech,
        // which splits or repeats words at the seam. VAD cuts at silence.
        XCTAssertEqual(options.chunkingStrategy, .vad)
        #endif
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter STTClientTests/testWhisperDecodeOptionsChunkAtSilenceNotFixedWindows 2>&1 | tail -5`
Expected: FAIL — `XCTAssertEqual failed: ("nil") is not equal to ("Optional(vad)")`.

- [ ] **Step 3: Set the strategy**

In `makeDecodingOptions`, add one argument to the `DecodingOptions(` call, after `noSpeechThreshold:`:

```swift
            noSpeechThreshold: Float(tuning.noSpeechThreshold),
            chunkingStrategy: .vad
```

- [ ] **Step 4: Run the Whisper tests**

Run: `swift test --filter 'STTClientTests|WhisperTuningPreset' 2>&1 | tail -5`
Expected: all pass, including the two pre-existing prefill-prompt tests.

- [ ] **Step 5: Measure**

```bash
swift build -c release --product macparakeet-cli
benchmarks/echelon/run.sh whisper-vad --engine whisper
```

Expected: WER ≤ `whisper-baseline`. If it is worse by more than the CI, stop and report — do not proceed on assumption.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacParakeetCore/STT/WhisperEngine.swift Tests/MacParakeetTests/STT/STTClientTests.swift
git commit -m "fix(whisper): chunk at silence (VAD) instead of fixed 30 s windows"
```

### Task 4: Feed Whisper the Custom Words list as a glossary prompt

**Files:**
- Modify: `Sources/MacParakeetCore/STT/WhisperEngine.swift` (init at 126-136; `makeDecodingOptions` 397-415; `transcribeWithLanguageFallback` 415-438)
- Modify: `Sources/MacParakeetCore/STT/STTRuntime.swift` (init 68-76; the three `WhisperEngine(model:` constructions at 117, 211, 432)
- Modify: `Sources/MacParakeet/App/AppEnvironment.swift:69-72`
- Test: `Tests/MacParakeetTests/STT/STTClientTests.swift`

**Interfaces:**
- Produces: `WhisperEngine.init(..., vocabularyProvider: (@Sendable () -> [String])? = nil)`; `static func makeVocabularyPrompt(terms: [String], maxCharacters: Int = 600) -> String?`; `makeDecodingOptions(language:tuning:promptTokens:)` with `promptTokens: [Int]? = nil`.
- Produces: `STTRuntime.init(..., whisperVocabularyProvider: (@Sendable () -> [String])? = nil)` forwarded to every `WhisperEngine` it builds.
- Consumes: `CustomWordRepository.fetchEnabled() throws -> [CustomWord]` (`Sources/MacParakeetCore/Database/CustomWordRepository.swift:40`), `CustomWord.word: String`, `CustomWord.replacement: String?`.

- [ ] **Step 1: Write the failing tests for the prompt builder**

```swift
    func testVocabularyPromptJoinsUniqueTermsAndCapsLength() {
        let prompt = WhisperEngine.makeVocabularyPrompt(
            terms: ["Echelon", "FitPass", "echelon", "  ", "cadence"])
        XCTAssertEqual(prompt, "Glossary: Echelon, FitPass, cadence.")

        let long = WhisperEngine.makeVocabularyPrompt(
            terms: (0..<200).map { "instructorname\($0)" }, maxCharacters: 120)
        XCTAssertNotNil(long)
        XCTAssertLessThanOrEqual(long!.count, 120)
        XCTAssertTrue(long!.hasSuffix("."))
    }

    func testVocabularyPromptIsNilWhenNoTerms() {
        XCTAssertNil(WhisperEngine.makeVocabularyPrompt(terms: []))
        XCTAssertNil(WhisperEngine.makeVocabularyPrompt(terms: ["", "  "]))
    }

    func testWhisperDecodeOptionsCarryPromptTokens() {
        #if canImport(WhisperKit)
        let options = WhisperEngine.makeDecodingOptions(language: "en", promptTokens: [50257, 9012])
        XCTAssertEqual(options.promptTokens, [50257, 9012])
        XCTAssertNil(WhisperEngine.makeDecodingOptions(language: "en").promptTokens)
        #endif
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter 'STTClientTests/testVocabularyPrompt|STTClientTests/testWhisperDecodeOptionsCarryPromptTokens' 2>&1 | tail -8`
Expected: compile error `type 'WhisperEngine' has no member 'makeVocabularyPrompt'` (a compile failure counts as the failing state here).

- [ ] **Step 3: Add the prompt builder and the option pass-through**

In `WhisperEngine.swift`, next to `makeDecodingOptions`:

```swift
    /// Builds Whisper's optional initial prompt from the user's Custom Words.
    /// Whisper treats the prompt as "text that came before", so a comma list of
    /// proper nouns steers spelling (instructor names, product names) without
    /// changing what is recognised. Capped so it never crowds out the 224-token
    /// prompt window; WhisperKit trims to the model limit as well.
    static func makeVocabularyPrompt(terms: [String], maxCharacters: Int = 600) -> String? {
        var seen = Set<String>()
        var kept: [String] = []
        for raw in terms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            kept.append(term)
        }
        guard !kept.isEmpty else { return nil }
        var prompt = "Glossary: "
        for (index, term) in kept.enumerated() {
            let piece = (index == 0 ? "" : ", ") + term
            guard prompt.count + piece.count + 1 <= maxCharacters else { break }
            prompt += piece
        }
        return prompt + "."
    }
```

Change `makeDecodingOptions` to accept and forward tokens:

```swift
    static func makeDecodingOptions(
        language: String?,
        tuning: WhisperEngineTuning = SpeechEnginePreference.whisperTuning(),
        promptTokens: [Int]? = nil
    ) -> DecodingOptions {
        let resolvedLanguage = SpeechEnginePreference.normalizeLanguage(language)
        return DecodingOptions(
            language: resolvedLanguage,
            temperature: Float(tuning.temperature),
            topK: tuning.topK,
            usePrefillPrompt: resolvedLanguage != nil,
            detectLanguage: resolvedLanguage == nil,
            wordTimestamps: true,
            promptTokens: promptTokens,
            compressionRatioThreshold: Float(tuning.compressionRatioThreshold),
            logProbThreshold: Float(tuning.logProbThreshold),
            noSpeechThreshold: Float(tuning.noSpeechThreshold),
            chunkingStrategy: .vad
        )
    }
```

- [ ] **Step 4: Store the provider on the engine and tokenise at transcribe time**

In `WhisperEngine.init` add a stored property and parameter:

```swift
    private let vocabularyProvider: (@Sendable () -> [String])?

    public init(
        model: String = WhisperEngine.defaultModelVariant,
        language: String? = nil,
        downloadBase: URL? = nil,
        defaults: UserDefaults = .standard,
        vocabularyProvider: (@Sendable () -> [String])? = nil
    ) {
        self.modelVariant = Self.normalizeModelVariant(model)
        self.defaultLanguage = SpeechEnginePreference.normalizeLanguage(language)
        self.downloadBase = downloadBase ?? Self.defaultDownloadBase
        self.defaults = defaults
        self.vocabularyProvider = vocabularyProvider
    }
```

In `transcribeWithLanguageFallback`, compute the tokens once and pass them to both `makeDecodingOptions` calls. `transcribeWithLanguageFallback` is `static`, so add a `promptTokens: [Int]?` parameter to it and compute the tokens at its call site (the instance method that owns `whisperKit`):

```swift
        let promptTokens: [Int]? = {
            guard let terms = vocabularyProvider?(), !terms.isEmpty,
                  let prompt = Self.makeVocabularyPrompt(terms: terms),
                  let tokenizer = whisperKit.tokenizer else { return nil }
            return tokenizer.encode(text: " " + prompt)
        }()
```

and in both `makeDecodingOptions(language: ..., tuning: tuning)` calls append `, promptTokens: promptTokens`.

- [ ] **Step 5: Thread the provider through `STTRuntime`**

`STTRuntime.init` gains `whisperVocabularyProvider: (@Sendable () -> [String])? = nil`, stored as `private let whisperVocabularyProvider`. Each of the three `WhisperEngine(model: whisperModelVariant ...)` constructions (lines 117, 211, 432) becomes `WhisperEngine(model: whisperModelVariant, vocabularyProvider: whisperVocabularyProvider)` (the 432 site already passes extra arguments; add the new one at the end).

- [ ] **Step 6: Wire the app**

`AppEnvironment.swift:69-72`:

```swift
        let vocabularyRepo = customWordRepo
        sttRuntime = STTRuntime(
            speechEngine: SpeechEnginePreference.current(),
            whisperModelVariant: SpeechEnginePreference.whisperModelVariant(),
            whisperVocabularyProvider: {
                ((try? vocabularyRepo.fetchEnabled()) ?? []).map { $0.replacement ?? $0.word }
            }
        )
```

If Swift 6 strict concurrency rejects capturing the repository, wrap it: `final class SendableBox<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }` in the same file and capture `SendableBox(customWordRepo)`. `CustomWordRepository` only holds a GRDB `DatabaseQueue`, which is thread-safe.

The CLI path (`STTClient`) passes no provider → prompt is nil → unchanged behaviour. Fine: the benchmark measures the recogniser, not the glossary.

- [ ] **Step 7: Run tests and build the app**

Run: `swift test --filter 'STTClientTests|STTRuntime|STTScheduler' 2>&1 | tail -5 && swift build 2>&1 | tail -2`
Expected: all pass; build succeeds with no new warnings about Sendable.

- [ ] **Step 8: Manual check**

In Echo Dev (`scripts/dev/run_app.sh`), add Custom Words `Echelon`, `FitPass`, and one instructor name that Whisper misspells in the baseline transcripts. Re-transcribe one fixture clip through the app; confirm the spelling is fixed in the raw transcript. Record the before/after word in the commit message.

- [ ] **Step 9: Commit**

```bash
git add Sources/MacParakeetCore/STT/WhisperEngine.swift Sources/MacParakeetCore/STT/STTRuntime.swift Sources/MacParakeet/App/AppEnvironment.swift Tests/MacParakeetTests/STT/STTClientTests.swift
git commit -m "feat(whisper): prime the decoder with Custom Words as a glossary prompt"
```

### Task 5: Pin Whisper to English and gate Phase 1

**Files:** none (Settings + measurement). Modify: `benchmarks/echelon/README.md` (append numbers).

- [ ] **Step 1: Pin the language**

Echo → Settings → Engine → Whisper Language card → choose **English**. Verify: `defaults read com.echelonfit.echo | grep -i whisperLanguage` shows `en`. (The engine then uses `usePrefillPrompt: true` and stops re-detecting language every window. `SpeechEnginePreference.whisperDefaultLanguage()` already exists; upstream ADR-021 documents the card.)

- [ ] **Step 2: Measure the whole Phase 1 stack**

```bash
swift build -c release --product macparakeet-cli
benchmarks/echelon/run.sh whisper-phase1 --engine whisper --language en
benchmarks/asr/venv/bin/python benchmarks/asr/score.py benchmarks/echelon/results/whisper-baseline.jsonl benchmarks/echelon/results/whisper-phase1.jsonl
```

Expected: `whisper-phase1` WER lower than `whisper-baseline`. Append both rows to `benchmarks/echelon/README.md`.

- [ ] **Step 3: Full suite, install, merge to main**

```bash
swift test 2>&1 | tail -3
scripts/dev/install_local.sh
git add benchmarks/echelon/README.md && git commit -m "bench: record Phase 1 Whisper numbers"
git checkout main && git merge --ff-only upgrade/phase0-yardstick && git push origin main
```

Expected: `Executed 3255+ tests, with 0 failures`; `/Applications/Echo.app` relaunches with the new build; `main` fast-forwards.

---

## Phase 2 — Upstream sync

### Task 6: Merge `upstream/main` (v0.7.3 + 0.8.0 QA) into the fork

**Files:** 46 conflicting files, listed in the trial-merge inventory. Highest-effort: `Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift` (77 hunks, mostly whitespace), `Sources/MacParakeetCore/Services/ExportService.swift` (20), `Sources/MacParakeetCore/Services/TranscriptionService.swift` (7), `Package.swift` / `Package.resolved`, `CLAUDE.md`, `AGENTS.md`.

**Interfaces:**
- Produces: a fork on FluidAudio 0.15.6 with `ParakeetModelVariant.unified`, `CohereTranscribeEngine`, `CustomVocabularyBoosting`, `SpeechEngineCapabilities`, the batch CLI, and all fork-only features intact.

- [ ] **Step 1: Branch and pin the incoming commit**

```bash
git checkout main && git checkout -b upgrade/phase2-upstream-sync
git fetch upstream
git rev-parse upstream/main > /tmp/echo-sync-target.txt && cat /tmp/echo-sync-target.txt
```

Record that SHA in the eventual merge commit message so the sync is reproducible.

- [ ] **Step 2: Merge, ignoring end-of-line whitespace**

```bash
git merge --no-ff -X ignore-space-at-eol upstream/main
git diff --name-only --diff-filter=U | tee /tmp/echo-conflicts.txt | wc -l
```

Expected: ≈46 files (fewer if `-X ignore-space-at-eol` collapses the whitespace hunks). Do NOT run `git merge --abort` after starting to resolve; if the merge must be restarted, `git reset --hard main` on this branch is the reset.

- [ ] **Step 3: Resolve the mechanical group first (docs, scripts, package manifests)**

- `Package.swift`: take upstream's dependency block **except** keep `argmax-oss-swift` at `exact: "1.0.0"` (fork) — upstream pins 0.18.0. Keep the `skipWhisperKit` env switch from both sides.
- `Package.resolved`: after resolving `Package.swift`, run `swift package resolve` and `git add Package.resolved`; do not hand-merge it.
- `CLAUDE.md`, `AGENTS.md`: take upstream, then re-insert the fork's "This is a Personal Fork" section verbatim at the top of `CLAUDE.md`.
- `spec/*.md`, `spec/adr/017-*.md`: take upstream (`git checkout --theirs -- spec && git add spec`); the fork's only spec edit was calendar wording that upstream now owns.
- `scripts/dev/run_app.sh`, `scripts/dist/build_app_bundle.sh`: keep the fork's Echo naming (`Echo-Dev.app`, `com.echelonfit.echo`) and take upstream's new steps (Sparkle embedding, `3827999d`).

- [ ] **Step 4: Resolve `WhisperEngine.swift` (2 hunks)**

Keep Task 3/4's `chunkingStrategy: .vad`, `promptTokens`, and `vocabularyProvider`; take upstream's `#812` indeterminate-progress changes. After resolving, `swift build --target MacParakeetCore 2>&1 | grep -c error:` must print `0`.

- [ ] **Step 5: Resolve `ExportService.swift` (20 hunks)**

Rule: **fork wins for every subtitle-cue function** (`SubtitleExportConfig`, `buildSubtitleCues`, `enforceMinDuration`, `enforceMinGap`, `applyEndTimeBuffer`, `mergeOrphanedCues`, reading-speed and frame-snap passes, `WordNumberSplitter` call sites); **upstream wins for** DAPT export (`609ec336`), Dark-Mode PDF/DOCX legibility (`609d636e`), bulk export (`45e4eb2a`), and any speaker-attribution changes. When a hunk mixes both, take the fork's cue logic and re-apply upstream's additive lines around it. Verify with `swift test --filter 'SubtitleExport|ExportService' 2>&1 | tail -3` → 0 failures.

- [ ] **Step 6: Resolve `TranscriptionService.swift` (7) and `TextProcessingPipeline.swift` / `TextRefinementService.swift` (2 each)**

Fork wins for `NumberLLMRefiner` composition (`71fab692`) and `numberRefinementMode` (`c4247e0f`); upstream wins for engine-routing changes (`0dd4810e`, `90dd0e89`) and vocabulary corrections on meeting transcripts (`75bf8d0f`). Verify: `swift test --filter 'TranscriptionService|NumberLLMRefiner|NumberNormalizer|TextProcessing' 2>&1 | tail -3`.

- [ ] **Step 7: Resolve the UI files**

`TranscriptResultView.swift` (77): first try `git checkout --theirs -- Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift`, then re-apply the fork's two-phase export progress overlay (`a972f3e1`, `a2d145f9`, `92c1127b`) and the AI Subtitle Refinement affordances by cherry-reading those commits (`git show <sha> -- <file>`). `SettingsView.swift`, `SettingsViewModel.swift`, `SettingsSearchIndex.swift`: take upstream, then re-add the fork's `SubtitleRefinementCard`, `NumberFormattingCard`, and Whisper tuning preset picker entries. `DesignSystem.swift`, `MacParakeetApp.swift`, `BreathWaveIcon.swift`, `OnboardingFlowView.swift`: fork wins for palette/branding/onboarding-window-resize; upstream wins for anything else. `CustomWordsView.swift`: upstream (bulk delete) — fork had no functional change there.

- [ ] **Step 8: Resolve the remaining core files**

`AppEnvironment.swift` (Task 4 wiring + upstream's new services), `AppFeatures.swift` (keep `calendarEnabled = false`), `AppRuntimePreferences.swift` + its test, `DatabaseManager.swift` (take upstream migrations; the fork added none), `Transcription.swift`, `TranscriptionProgress.swift`, `STTResult.swift`, `STTRuntime.swift` (Task 4's `whisperVocabularyProvider` + upstream's engine roster), `AutoSaveService.swift`, `DictationService.swift`, `PromptResultsViewModel.swift`, CLI `ExportCommand.swift`/`TranscribeCommand.swift` (upstream, then re-add `--subtitle-preset`).

- [ ] **Step 9: Build clean, then full tests**

```bash
git diff --name-only --diff-filter=U | wc -l    # must be 0
swift build 2>&1 | grep -E 'error:|warning: .*Sendable' | head
swift test 2>&1 | tail -5
```

Expected: 0 unresolved, 0 errors, `0 failures`. Any failing fork test (`SubtitleExportTests`, `NumberLLMRefinerTests`, `WhisperTuningPresetTests`, `WordNumberSplitterTests`, `NumberNormalizerTests`) means a fork feature was lost in Step 5–8 — fix before continuing; do not delete the test.

- [ ] **Step 10: Commit the merge**

```bash
git add -A
git commit -m "merge: sync upstream/main $(cat /tmp/echo-sync-target.txt | cut -c1-8) (v0.7.3 + 0.8.0 QA) into Echo

Keeps fork-only subtitle presets, LLM cue planner/reviewer, number refiner,
Whisper tuning presets, Echo branding; keeps argmax-oss-swift 1.0.0.
Brings FluidAudio 0.15.6, Parakeet Unified, Cohere Transcribe, vocabulary
boosting, capability registry, batch CLI, DAPT export, diarization fixes."
```

### Task 7: Post-sync smoke, install, and regression gate

**Files:** Modify: `benchmarks/echelon/README.md`; Modify: `CLAUDE.md` (fork section: update "Custom features in this fork" + sync date).

- [ ] **Step 1: Smoke the four things that matter to Echelon**

```bash
scripts/dev/install_local.sh
```
Then in Echo: (a) drop one class video → transcript appears; (b) Export → SRT with the saved options → open the .srt, spot-check three cues against the video; (c) Settings → Engine shows Parakeet Model card with `English (Unified)`; (d) Settings → AI tab still shows Subtitle Refinement and Number Formatting cards.

- [ ] **Step 2: Regression-check Whisper accuracy did not move**

```bash
swift build -c release --product macparakeet-cli
benchmarks/echelon/run.sh whisper-postsync --engine whisper --language en
benchmarks/asr/venv/bin/python benchmarks/asr/score.py benchmarks/echelon/results/whisper-phase1.jsonl benchmarks/echelon/results/whisper-postsync.jsonl
```

Expected: WER within CI of `whisper-phase1`.

- [ ] **Step 3: Update the fork notes and gate**

In `CLAUDE.md` fork section: set "Last upstream sync: 2026-09-XX @ <sha>", note the WhisperKit pin decision, and add Task 3/4 to the custom-features list.

```bash
git add CLAUDE.md benchmarks/echelon/README.md
git commit -m "docs: record upstream sync and post-sync Whisper numbers"
git checkout main && git merge --ff-only upgrade/phase2-upstream-sync && git push origin main
git tag echo-post-sync-2026-09
```

---

## Phase 3 — Choose the caption engine by measurement

### Task 8: Engine bake-off on the Echelon fixture

**Files:** Modify: `benchmarks/echelon/README.md` (results table).

- [ ] **Step 1: Download the candidate models once**

```bash
.build/release/macparakeet-cli models download parakeet-unified
.build/release/macparakeet-cli models download cohere-transcribe     # ~2.1 GB, 16 GB+ RAM; this Mac has 64 GB
.build/release/macparakeet-cli models list
```

- [ ] **Step 2: Run every engine on the same clips**

```bash
benchmarks/echelon/run.sh parakeet-v3       --engine parakeet --parakeet-model v3
benchmarks/echelon/run.sh parakeet-unified  --engine parakeet --parakeet-model unified
benchmarks/echelon/run.sh whisper-en        --engine whisper  --language en
benchmarks/echelon/run.sh cohere-text       --engine cohere   --language en
```

Note wall time from each run; captions for a 45-minute class must finish in well under a coffee break.

- [ ] **Step 3: Compare with paired significance, not eyeballing**

```bash
git checkout upstream/main -- benchmarks/asr/paired_delta.py 2>/dev/null || true
benchmarks/asr/venv/bin/python benchmarks/asr/paired_delta.py benchmarks/echelon/results/whisper-en.jsonl benchmarks/echelon/results/parakeet-unified.jsonl
benchmarks/asr/venv/bin/python benchmarks/asr/paired_delta.py benchmarks/echelon/results/parakeet-unified.jsonl benchmarks/echelon/results/cohere-text.jsonl
```

- [ ] **Step 4: Also inspect the failure modes by hand**

For the worst-scoring clip per engine, diff `results/<label>/<clip>.txt` against `refs/<clip>.txt`. Classify errors: music-hallucination, dropped countdown numbers, name misspellings, fused tokens (`next30`). This drives which vocabulary/normaliser rules matter in Phase 4.

- [ ] **Step 5: Record and decide**

Append a table (engine, WER, CI, wall time, word timestamps yes/no) to `benchmarks/echelon/README.md`. Decision rule: pick the lowest-WER engine that **provides word timestamps**. If that is not Parakeet Unified, this plan's Task 9 still applies with the winning engine substituted. If Cohere's text beats the winner by more than 1 WER point, open a follow-up plan for Cohere-text + Parakeet-timing alignment; do not attempt it here.

```bash
git add benchmarks/echelon/README.md && git commit -m "bench: engine bake-off results on Echelon fixture"
```

### Task 9: Make the winner Echo's default and make a mistake impossible

**Files:**
- Modify: `Sources/MacParakeetCore/Models/SpeechEnginePreference.swift` (default `parakeetModelVariant`)
- Test: `Tests/MacParakeetTests/STT/STTClientTests.swift`

**Interfaces:**
- Consumes: upstream `SpeechEnginePreference.parakeetModelVariant(defaults:) -> ParakeetModelVariant` and `.parakeetModelVariantKey` (see upstream `spec/06-stt-engine.md` § "Parakeet model variant").

- [ ] **Step 1: Write the failing test**

```swift
    func testEchoDefaultsToParakeetUnifiedForEnglishCaptions() {
        let suiteName = "com.echelonfit.tests.default-variant.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Echo captions English classes; Unified is the best English build that
        // keeps word timestamps (bake-off, benchmarks/echelon/README.md).
        XCTAssertEqual(SpeechEnginePreference.current(defaults: defaults), .parakeet)
        XCTAssertEqual(SpeechEnginePreference.parakeetModelVariant(defaults: defaults), .unified)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter STTClientTests/testEchoDefaultsToParakeetUnifiedForEnglishCaptions 2>&1 | tail -4`
Expected: FAIL — variant is `.v3`.

- [ ] **Step 3: Change the default**

In `SpeechEnginePreference`, where the variant is read with a `.v3` fallback, change the fallback to `.unified`. Add a comment pointing at the bake-off table. Do NOT touch upstream's migration logic for existing installs; a one-shot migration is unnecessary because Justin's install currently has no `parakeetModelVariant` key (it read `None` on 2026-09-08).

- [ ] **Step 4: Run tests, then switch the live app**

Run: `swift test --filter 'STTClientTests|SpeechEnginePreference|Capabilit' 2>&1 | tail -3`
Then in Echo: Settings → Engine → **Parakeet**, Parakeet Model → **English (Unified)**. Confirm `defaults read com.echelonfit.echo speechRecognitionEngine` = `parakeet`.

- [ ] **Step 5: Caption one full class end to end and eyeball timing**

Transcribe a whole class in Echo, export SRT, load it in QuickTime/VLC with the video. Check: cues appear as words are said (not late), countdown numbers render as `3, 2, 1` per `numberRefinementMode: smart`, no fused `next30`. Any regression here is a Phase 4 vocabulary/normaliser item, not a reason to revert the engine.

- [ ] **Step 6: Commit and gate**

```bash
git add Sources/MacParakeetCore/Models/SpeechEnginePreference.swift Tests/MacParakeetTests/STT/STTClientTests.swift
git commit -m "feat(stt): default Echo to Parakeet Unified for English captions (bake-off winner)"
swift test 2>&1 | tail -3 && scripts/dev/install_local.sh
git checkout main && git merge --ff-only upgrade/phase3-engine && git push origin main
```

(Phase 3 work happens on `upgrade/phase3-engine`, branched from `main` after Task 7.)

---

## Phase 4 — Utility

### Task 10: "Echelon" caption preset

**Files:**
- Modify: `Sources/MacParakeetCore/Services/ExportService.swift` (the `SubtitleExportConfig` preset enum/static presets, next to `.standard/.netflix/.bbc/.youtube`)
- Modify: Settings preset picker + `--subtitle-preset` CLI enum (same files that list the four existing presets; locate with `grep -rn "netflix" Sources | grep -v Tests`)
- Test: `Tests/MacParakeetTests/SubtitleExportTests.swift`

**Interfaces:**
- Produces: `SubtitleExportConfig.echelon: SubtitleExportConfig` and preset id `echelon`.

- [ ] **Step 1: Write the failing test**

```swift
    func testEchelonPresetPinsTodaysTunedCaptionValues() {
        let c = SubtitleExportConfig.echelon
        XCTAssertEqual(c.maxCharsPerLine, 65)
        XCTAssertEqual(c.maxLinesPerCue, 2)
        XCTAssertEqual(c.maxDurationMs, 4000)
        XCTAssertEqual(c.maxCPS, 17)
        XCTAssertEqual(c.endTimeBufferMs, 1000)
        XCTAssertEqual(c.snapToFrameRate, 29.97)
        XCTAssertEqual(c.minWordsBeforePunctuationBreak, 4)
        XCTAssertEqual(c.reviewerPairsPerBatch, 5)
        XCTAssertTrue(c.breakOnPunctuation)
        XCTAssertTrue(c.preferBalancedLines)
        XCTAssertTrue(c.useLLMRefinement)
        XCTAssertFalse(c.normalizeNumbers)   // numbers handled by NumberRefinementMode.smart instead
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter SubtitleExportTests/testEchelonPresetPinsTodaysTunedCaptionValues 2>&1 | tail -4`
Expected: compile error — no member `echelon`.

- [ ] **Step 3: Add the preset**

Beside the existing presets:

```swift
    /// Echelon class captions: 29.97 fps video, two 65-char lines, held ~1 s
    /// after the last word so cues do not flicker between shouted cues.
    /// Values copied from the production Echo install on 2026-09-08.
    public static let echelon = SubtitleExportConfig(
        maxWordsPerCue: 12, maxCharsPerLine: 65, maxLinesPerCue: 2, maxDurationMs: 4000,
        gapThresholdMs: 0, breakOnPunctuation: true, minWordsBeforePunctuationBreak: 4,
        preferBalancedLines: true, useLLMRefinement: true, maxCPS: 17,
        endTimeBufferMs: 1000, snapToFrameRate: 29.97, normalizeNumbers: false,
        reviewerPairsPerBatch: 5
    )
```

(Match the memberwise initialiser's actual parameter order; if a parameter is missing from the list above because upstream added one, use its default.) Register `echelon` in the preset picker and the CLI `--subtitle-preset` enum, and make it the fork's default preset where `.standard` is currently the default.

- [ ] **Step 4: Run tests, commit**

Run: `swift test --filter 'SubtitleExport|ExportCommand|SubtitlePreset' 2>&1 | tail -3`

```bash
git add -A Sources Tests && git commit -m "feat(subtitle): Echelon caption preset (29.97 fps, 65x2, 1 s hold) as the default"
```

### Task 11: Seed Echelon vocabulary and turn on recognition boosting

**Files:**
- Create: `benchmarks/echelon/vocabulary.txt` (one term per line; instructor names, "Echelon", "FitPass", "Echelon Reflect", class-cue terms found in Task 8 Step 4). Committing names is fine; they are public instructor names.
- Uses: existing Vocabulary import (`VocabularyImportExportService.swift`) — no new code unless import lacks a plain-text path.

- [ ] **Step 1: Build the list from the bake-off error analysis**

Take every misspelled proper noun from Task 8 Step 4 plus the known brand terms. Keep under ~80 terms so the Whisper glossary prompt (600 chars) and the CTC sidecar stay cheap.

- [ ] **Step 2: Import and enable boosting**

Echo → Vocabulary → Import → `benchmarks/echelon/vocabulary.txt`. Settings → Vocabulary → turn on "Recognition boosting" (`customVocabularyRecognitionBoostingEnabled`, default off upstream #777). Note from the capability table: boosting applies to Parakeet **v2/v3** (`supportsCustomVocabulary: !variant.usesUnifiedEngine`); on Unified the words still run as post-transcription corrections, and on Whisper they feed the Task 4 glossary prompt. FluidAudio 0.15.6 added Unified boosting upstream-of-upstream; if MacParakeet wires it later, a sync picks it up.

- [ ] **Step 3: Measure the effect**

```bash
benchmarks/echelon/run.sh parakeet-unified-vocab --engine parakeet --parakeet-model unified
benchmarks/asr/venv/bin/python benchmarks/asr/score.py benchmarks/echelon/results/parakeet-unified.jsonl benchmarks/echelon/results/parakeet-unified-vocab.jsonl
```

(Stays on run.sh's pinned `--mode raw`: upstream's CTC vocabulary boosting acts inside the recogniser, so it is visible raw; post-transcription word replacements are deliberately NOT measured here.) Record in the README.

```bash
git add benchmarks/echelon/vocabulary.txt benchmarks/echelon/README.md
git commit -m "vocab: seed Echelon terms; record boosting effect"
```

### Task 12: One-command batch captioning for a folder of classes

**Files:**
- Create: `scripts/echelon/caption_folder.sh`
- Modify: `CLAUDE.md` fork section (document the script)

**Interfaces:**
- Consumes: upstream CLI `transcribe <folder> --output-dir <dir> --format srt --engine parakeet --parakeet-model unified --mode clean` (folders and `--output-dir` exist post-sync).

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Caption every video in a folder to SRT (and VTT) using Echo's engine + preset.
# Usage: scripts/echelon/caption_folder.sh "/Volumes/Classes/2026-09" [output-dir]
set -euo pipefail
IN="$1"; OUT="${2:-$1/captions}"
CLI="${CLI:-/Applications/Echo.app/Contents/MacOS/macparakeet-cli}"
[ -x "$CLI" ] || CLI="$(cd "$(dirname "$0")/../.." && pwd)/.build/release/macparakeet-cli"
mkdir -p "$OUT"
for fmt in srt vtt; do
  "$CLI" transcribe "$IN" --output-dir "$OUT" --format "$fmt" \
      --engine app-default --parakeet-model app-default --mode clean --speaker-detection off
done
echo "Captions written to $OUT:"; ls -1 "$OUT"
```

`--engine app-default` follows whatever Settings says, so switching engines in the app changes batch output too. Confirm the bundled CLI path with `ls /Applications/Echo.app/Contents/MacOS/`; if the CLI is not bundled by `build_app_bundle.sh`, the fallback release build is used.

- [ ] **Step 2: Test on a folder of two short clips**

```bash
mkdir -p /tmp/echo-batch && cp benchmarks/echelon/clips/*-00.m4a benchmarks/echelon/clips/*-01.m4a /tmp/echo-batch/
chmod +x scripts/echelon/caption_folder.sh && scripts/echelon/caption_folder.sh /tmp/echo-batch
head -12 /tmp/echo-batch/captions/*-00.srt
```

Expected: one `.srt` and one `.vtt` per input; first cue starts near `00:00:00` and text matches the clip.

- [ ] **Step 3: Document and commit**

Add to `CLAUDE.md` fork section: "Batch captions: `scripts/echelon/caption_folder.sh <folder>`". Then:

```bash
git add scripts/echelon/caption_folder.sh CLAUDE.md
git commit -m "feat(echelon): one-command folder captioning via the bundled CLI"
swift test 2>&1 | tail -3
git checkout main && git merge --ff-only upgrade/phase4-utility && git push origin main
```

---

## Phase 5 — Optional, after everything above is live

### Task 13: WhisperKit 1.0.0 → 1.1.0

**Files:** Modify: `Package.swift` (`exact: "1.1.0"`), `Package.resolved` (via `swift package resolve`).

- [ ] **Step 1:** Change the pin, `swift package resolve`, `swift build`. Expected: builds; the 1.1.0 changelog lists no WhisperKit API breaks (incremental file loading, `promptTokens` empty-transcription fix, timestamp fixes).
- [ ] **Step 2:** `swift test --filter 'STTClientTests|WhisperTuningPreset|STTRuntime'` → 0 failures.
- [ ] **Step 3:** `benchmarks/echelon/run.sh whisper-1.1 --engine whisper --language en` → within CI of `whisper-postsync`.
- [ ] **Step 4:** Commit `chore(deps): WhisperKit (argmax-oss-swift) 1.1.0`.

**Deferred (needs its own plan):** Cohere-text + Parakeet-timing hybrid alignment, if Task 8 shows a >1 pt gap. Apple SpeechTranscriber spike (macOS 26 only, no benchmark). Canary-1B-v2 (FluidAudio 0.15.6 beta; not surfaced by upstream MacParakeet yet).

---

## Self-review

- **Spec coverage.** Decision 1 → Tasks 8–9. Decision 2 → Tasks 3–5. Decision 3 → Task 2 (and every task's measure step). Decision 4 → Tasks 6–7. Decision 5(a) → Task 12, (b) → Task 10, (c) → Tasks 4 and 11. Non-goals are listed and none has a task.
- **Placeholders.** None: every code step has code; the merge task names exact win/lose rules per file; the human-only steps (reference correction, Settings clicks) are labelled as such.
- **Type consistency.** `makeDecodingOptions(language:tuning:promptTokens:)` (Task 4) is what Task 6 Step 4 preserves. `vocabularyProvider` / `whisperVocabularyProvider` names match across Tasks 4 and 6. `run.sh <label> <flags>` output paths `results/<label>.jsonl` are used identically in Tasks 3, 5, 7, 8, 11, 13. `SubtitleExportConfig.echelon` (Task 10) is the preset id `echelon` in the CLI.
- **Risk register.** Task 6 is the only task that can silently lose work; its gate is "every fork test still exists and passes". Tag `echo-pre-upgrade-2026-09-08` is the global undo.
