#!/usr/bin/env bash
# Caption every video in a folder to SRT and VTT using Echo's engine + the Echelon preset.
# Usage: scripts/echelon/caption_folder.sh "/Volumes/Classes/2026-09" [output-dir]
# Note: the Echelon preset's AI cue refinement (useLLMRefinement) runs in the
# app and in `macparakeet-cli export`; this script's `transcribe` pass produces
# deterministic cue layout without it.
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: $0 <folder> [output-dir]" >&2; exit 2; }
IN="$1"; OUT="${2:-$1/captions}"
CLI="${CLI:-/Applications/Echo.app/Contents/MacOS/macparakeet-cli}"

# Prefers the installed app's CLI; reinstall the app after changing the preset in the repo.
pick_cli() {
  local help
  help="$("$CLI" transcribe --help 2>/dev/null || true)"
  case "$help" in
    *--subtitle-preset*) return ;;
  esac
  local fallback
  fallback="$(cd "$(dirname "$0")/../.." && pwd)/.build/release/macparakeet-cli"
  if [ -x "$fallback" ]; then
    help="$("$fallback" transcribe --help 2>/dev/null || true)"
    case "$help" in
      *--subtitle-preset*) CLI="$fallback"; return ;;
    esac
  fi
  echo "error: no macparakeet-cli with --subtitle-preset support found (checked $CLI and $fallback)" >&2
  exit 1
}
pick_cli

mkdir -p "$OUT"

status=0
"$CLI" transcribe "$IN" --output-dir "$OUT" --format srt \
    --engine app-default --parakeet-model app-default --mode clean --speaker-detection off --subtitle-preset echelon \
    || status=$?

srt_count=0
for srt in "$OUT"/*.srt; do
  [ -e "$srt" ] || continue
  srt_count=$((srt_count + 1))
  vtt="${srt%.srt}.vtt"
  {
    echo "WEBVTT"
    echo
    sed -E 's/([0-9]{2}:[0-9]{2}:[0-9]{2}),([0-9]{3})/\1.\2/g' "$srt"
  } > "$vtt"
done

echo "Captions written to $OUT ($srt_count SRT file(s), $srt_count VTT file(s) derived):"; ls -1 "$OUT"
if [ "$status" -ne 0 ]; then
  echo "WARNING: the transcriber reported failures for some inputs (exit $status); check the output above." >&2
fi
exit "$status"
