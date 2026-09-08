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
