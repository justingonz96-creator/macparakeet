#!/usr/bin/env bash
# Caption every video in a folder to SRT and VTT using Echo's engine + the Echelon preset.
# Usage: scripts/echelon/caption_folder.sh "/Volumes/Classes/2026-09" [output-dir]
set -euo pipefail
IN="$1"; OUT="${2:-$1/captions}"
CLI="${CLI:-/Applications/Echo.app/Contents/MacOS/macparakeet-cli}"

pick_cli() {
  if "$CLI" transcribe --help 2>/dev/null | grep -q -- '--subtitle-preset'; then
    return
  fi
  local fallback
  fallback="$(cd "$(dirname "$0")/../.." && pwd)/.build/release/macparakeet-cli"
  if [ -x "$fallback" ] && "$fallback" transcribe --help 2>/dev/null | grep -q -- '--subtitle-preset'; then
    CLI="$fallback"
    return
  fi
  echo "error: no macparakeet-cli with --subtitle-preset support found (checked $CLI and $fallback)" >&2
  exit 1
}
pick_cli

mkdir -p "$OUT"
for fmt in srt vtt; do
  "$CLI" transcribe "$IN" --output-dir "$OUT" --format "$fmt" \
      --engine app-default --parakeet-model app-default --mode clean --speaker-detection off --subtitle-preset echelon
done
echo "Captions written to $OUT:"; ls -1 "$OUT"
