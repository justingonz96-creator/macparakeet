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

## Baseline 2026-09

No hand-corrected references exist for this fixture (the owner cancelled that pass). Reference =
Cohere Transcribe output (pseudo-reference, ranking-grade only). Consequence: Cohere itself is not
scored (it is the reference, so it would trivially read 0% WER) — the numbers below rank the other
engines relative to Cohere, they are **not** absolute WER against ground truth.

**Fixture composition:** 4 clips, 2 minutes each (8 minutes total), cut from
`Melbas_Final_Presentation.mp4` (a talk, not a class) via `make_clips.sh melbas 4`. The two Echelon
scenic-ride videos (`15min-Corsica-Mountains-France-Ride.mp4`, `20min-Spain-Nature-Run_1080p.mp4`)
were probed with a 2-minute clip each at the 3:00 mark and transcribed with `parakeet-v3`: both
produced 0 words despite normal audio levels (-18.2/-11.4 dB mean volume), i.e. music/ambience only,
no instructor speech — both were excluded per the <80-word threshold.

| engine | WER vs Cohere (95% CI) | wall time (4 clips) | word timestamps | notes |
|---|---|---|---|---|
| parakeet-unified | 13.00% [6.32, 18.32] | 16s | yes (269 words, verified via `--format json`) | lowest WER; significantly better than parakeet-v3 (paired bootstrap) |
| whisper-en | 14.42% [8.24, 19.88] | 23s | yes (279 words) | statistically tied with parakeet-unified (paired CI spans 0) |
| parakeet-v3 | 14.58% [8.81, 19.81] | 5s | yes (274 words) | fastest wall time, but significantly worse WER than parakeet-unified |
| cohere-transcribe | — (is the reference) | 80s (4 clips, includes ~73s one-time model compile) | no | pseudo-reference only, not scored; no word timestamps at all (verified empty in `--format json`) |

Paired significance (`paired_delta.py`, 2000-sample bootstrap):
- `whisper-en` vs `parakeet-unified`: Δ=+1.42 WER, 95% CI [-0.49, +3.58] → tie (CI spans 0)
- `parakeet-v3` vs `parakeet-unified`: Δ=+1.58 WER, 95% CI [+0.29, +2.49] → SIGNIFICANT (parakeet-unified better)

**Failure-mode inspection** (worst clip for all three candidates was `melbas-00`, ~19-21% WER):
- Dropped words during rapid/overlapping speech: all three engines (parakeet-v3, parakeet-unified,
  whisper-en) drop the same run of words ("meet him. To write for television. Newbie, come on, meet
  you.") that Cohere caught — a stretch of fast or overlapping dialogue, not silence/music.
- Hallucinated boundary text: parakeet-v3 and whisper-en both insert a spurious leading "for." at the
  very start of the clip (a clip-cut artifact, not present in unified's output).
- Name/proper-noun spelling: parakeet-unified renders "Newby" where the reference has "Newbie,".
- Real word substitutions: parakeet-unified "are" for ref "do", "studying?" for ref "study?"; whisper-en
  "Where" for ref "What" — genuine content errors, not casing/punctuation.
- Several other diffs (e.g. "Oh," vs "Oh", "fancy!" vs "fancy", "sorry?" vs "sorry", "major?" vs "major")
  are casing/punctuation-only; the scorer normalizes both away, so they do not count toward WER.

**Decision:** default caption engine = parakeet-unified. It has the lowest WER, provides word
timestamps, and is statistically significantly better than parakeet-v3; it is not distinguishable
from whisper-en by the paired test but is nominally faster and already the app's other Parakeet
build. Cohere is excluded from the decision (it is the reference and has no word timestamps).

## Echelon vocabulary

Two files seed the app's custom vocabulary: `vocabulary.txt` (one term per line) and `vocabulary-bundle.json` (JSON bundle format). Import with `.build/release/macparakeet-cli vocab import --input benchmarks/echelon/vocabulary-bundle.json` (default `--policy skip` merges without replacing existing words). Terms include brand/product names (Echelon, FitPass, Reflect, Connect, Stride, Row, United, EX-3/5/8/Pro, Smart Connect) and class-specific vocabulary (cadence, resistance, RPM, FTP, watts, leaderboard, warm-up, cool-down) plus two instructor first names (Marc, Maribel). Recognition-time boosting (Settings → Vocabulary → Recognition boosting) only applies to Parakeet v2/v3; on Parakeet Unified (Echo's default) these words act as post-transcription corrections, and on Whisper they feed the glossary prompt. Add instructor names and class cues as you meet them.
