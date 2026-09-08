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
[ -x "$CLI" ] || (cd "$ROOT" && swift build -c release --product macparakeet-cli)
HYP="$HERE/results/$LABEL"; mkdir -p "$HYP"
START=$(date +%s)
for clip in "$HERE"/clips/*.m4a; do
  base="$(basename "${clip%.m4a}")"
  "$CLI" transcribe "$clip" --format text --mode raw --no-history --speaker-detection off "$@" > "$HYP/$base.txt"
done
END=$(date +%s)
echo "wall=$((END-START))s for $(ls "$HERE"/clips/*.m4a | wc -l | tr -d ' ') clips"
python3 "$HERE/build_records.py" "$LABEL" "$HYP" "$HERE/results/$LABEL.jsonl"
"$ROOT/benchmarks/asr/venv/bin/python" "$ROOT/benchmarks/asr/score.py" --ci 1000 "$HERE/results/$LABEL.jsonl"
