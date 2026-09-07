# Executed engine sample checks

Candidate: `8548c099af5ee2ab0ed4dd9efe757d85c498cca0`; DEBUG CLI 3.3.0, binary SHA-256 `db8626c81735d0484878f396cae83c6a911a6cba9ff97d0a9ee139eb2cdcf690`.

Host: Apple M4 Pro, 48 GB RAM, macOS 26.6.2. These are sequential short public-fixture inference checks. Other local work continued, so wall time is observational rather than a controlled performance benchmark. No microphone, speaker playback, saved preference changes or personal recordings were used.

| Case | Outcome | Wall time | Timed words |
|---|---|---:|---:|
| parakeet-v3-en | Completed | 15.3 s | 28 |
| parakeet-v2-en | Completed | 15.36 s | 28 |
| parakeet-unified-en | Completed | 12.97 s | 27 |
| nemotron-en | Completed | 16.59 s | 28 |
| cohere-en | Completed | 233.54 s | 0 |
| nemotron-ko | Completed | 21.93 s | 13 |
| nemotron-ja | Completed | 1.74 s | 1 |
| nemotron-zh | Completed | 0.96 s | 3 |
| cohere-ko | 240-second model-load limit | 240.22 s | 0 |
| cohere-ja | 240-second model-load limit | 243.78 s | 0 |
| cohere-zh | 240-second model-load limit | 240.47 s | 0 |

English Parakeet v2/v3/Unified and Cohere closely match the 28-word LibriSpeech reference, allowing punctuation and hyphenation. Multilingual Nemotron renders “flour fatten” for “flour fattened.” The CJK Nemotron outputs preserve script with some recognition substitutions and spoken-number forms. No corpus WER/CER or general accuracy claim is made from one sample per language.

Cohere English completed after 233.54 seconds; logs put about 218 seconds in encoder loading. Its CJK attempts exceeded the 240-second harness bound at the same stage. A five-second process sample showed CoreML/MIL weight dequantization work, not proof of a deadlock. Longer observation is required before treating these timeouts as language or inference failures. Cohere does not promise word timing; its successful result contains zero timed words.

Separate English Nemotron and Whisper Turbo were absent from the isolated cache and were not downloaded. macOS 14 behavior and other hardware are unverified.

The exact command arrays, fixture hashes and wall times are in [results.json](evidence/results.json). Individual result JSON and stderr files share the case name in `evidence/`. [Public fixture provenance and references](audio-review.md#public-prerecorded-fixture-inventory-observed) describe the source corpora.

Method: explicit engine/variant/language, `--mode raw --speaker-detection off --no-history --database <owned path> --format json`; per-process telemetry opt-out and isolated Foundation home. The initial runner summary looked for `text`; actual CLI output uses `rawTranscript`, which was independently inspected above. The original raw evidence is preserved.
