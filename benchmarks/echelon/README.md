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

_Pending: awaiting class video to cut clips (Task 2 Step 6)._
