#!/usr/bin/env bash
# Cut N two-minute mono 16 kHz excerpts from a class video, spaced evenly,
# so the fixture covers warm-up, work blocks with music, and cool-down.
# Usage: make_clips.sh <class-video> <short-name> [count=5]
set -euo pipefail
SRC="$1"; NAME="$2"; COUNT="${3:-5}"
HERE="$(cd "$(dirname "$0")" && pwd)"
FFMPEG="${FFMPEG:-/Applications/Echo.app/Contents/Resources/ffmpeg}"
mkdir -p "$HERE/clips"
DUR=$( { "$FFMPEG" -i "$SRC" 2>&1 || true; } | sed -n 's/.*Duration: \([0-9]*\):\([0-9]*\):\([0-9]*\).*/\1*3600+\2*60+\3/p' | bc)
[ -n "${DUR:-}" ] || { echo "could not read duration of $SRC" >&2; exit 1; }
[ "$DUR" -gt 180 ] || { echo "source is only ${DUR}s; need > 180s to cut ${COUNT} clips" >&2; exit 1; }
STEP=$(( (DUR - 120) / COUNT ))
for i in $(seq 0 $((COUNT-1))); do
  START=$(( 60 + i*STEP ))
  OUT="$HERE/clips/${NAME}-$(printf '%02d' $i).m4a"
  "$FFMPEG" -y -loglevel error -ss "$START" -t 120 -i "$SRC" -vn -ac 1 -ar 16000 -c:a aac -b:a 96k "$OUT"
  echo "wrote $OUT (start ${START}s)"
done
