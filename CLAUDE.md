# CLAUDE.md

@AGENTS.md

> Claude Code overlay for MacParakeet. Keep this file intentionally small:
> [`AGENTS.md`](./AGENTS.md) is the canonical cross-agent startup guide and is
> imported above.

## This is a Personal Fork

**Owner:** Justin (not a software engineer — Claude handles all engineering)

**Primary repo:** `justingonz96-creator/macparakeet` — this is where we build and ship from.

**Upstream:** `moona3k/macparakeet` — the original project. We sync from it periodically; we may submit PRs upstream as contributions but that is optional, not required.

**Last upstream sync:** 2026-09-08 @ a82ae130

**Git remote setup:**
```
origin    https://github.com/justingonz96-creator/macparakeet.git  ← primary (push here)
upstream  https://github.com/moona3k/macparakeet.git               ← sync source only
```

**To sync upstream improvements:**
```bash
git fetch upstream
git merge upstream/main   # resolve any conflicts, then commit
git push origin main
```

**Open upstream PRs (contributions, not dependencies):**
- #305 — Subtitle: configurable export with presets, min-duration, gap enforcement
- #307 — Subtitle preset picker: Settings, CLI flag, persistence (stacked on #305)
- #308 — Text processing: split fused letter+digit tokens (stacked on #307, draft)

These PRs contain work that is already shipping in this fork. If they get merged upstream, the next sync will be a clean no-op for those files.

**Custom features in this fork (relative to upstream `main`):**
- `SubtitleExportConfig` struct with Standard / Netflix / BBC / YouTube presets
- `enforceMinDuration` and `enforceMinGap` post-processing passes
- Subtitle preset picker in Settings (Modes tab, Transcription card) + `--subtitle-preset` CLI flag
- `WordNumberSplitter` — fixes fused Parakeet tokens like `next30` → `next 30` in both subtitle and text pipeline paths
- Whisper: VAD chunking (`chunkingStrategy: .vad`) and a Custom-Words glossary prompt (`WhisperEngine.makeVocabularyPrompt`, `vocabularyProvider`) — Tasks 3/4 of docs/superpowers/plans/2026-09-08-echo-accuracy-utility-upgrade.md
- WhisperKit pin: fork stays on argmax-oss-swift 1.0.0 (upstream pins 0.18.0); do not downgrade on sync.

---

## Claude-Specific Rules

- Treat Claude auto memory, chat history, old plans, and local notes as leads,
  not truth. Verify release, PR, CI, deploy, analytics, and current code state
  live before relying on them.
- Do not grow this file or auto memory by default. Promote durable lessons to
  the narrowest versioned surface: `AGENTS.md`, a subsystem README, spec/ADR,
  `docs/pr-review-workflow.md`, `docs/distribution.md`,
  `integrations/README.md`, or a skill.
- Use `.claude/rules/` or subdirectory `CLAUDE.md` only for Claude-specific
  path-scoped rules that should not load globally.
- When this file and `AGENTS.md` overlap, edit `AGENTS.md` unless the
  instruction only matters to Claude Code.
- If a rule must be enforced rather than merely suggested, prefer tests,
  scripts, hooks, or product code over another instruction line.

## Local-State Cautions

- Preserve dirty or unrelated worktrees. Fresh PR work belongs on a branch or
  worktree based on `origin/main`.
- Do not delete user databases, meeting session folders, source audio, lock
  files, or ignored private files unless the task explicitly asks for a
  recovery or discard flow.
- Ignored paths such as `.claude/`, `journal/`, `.build*`, `dist/`,
  `diagnostics/`, `logs/`, and local env/key files are not review scope unless
  the task names them.

## References

- Agent memory/instruction governance:
  [`docs/agent-memory-governance.md`](./docs/agent-memory-governance.md)
- Current feature/release state: [`spec/README.md`](./spec/README.md)
- PR workflow: [`docs/pr-review-workflow.md`](./docs/pr-review-workflow.md)
