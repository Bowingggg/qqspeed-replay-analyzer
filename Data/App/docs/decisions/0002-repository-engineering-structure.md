# ADR 0002 — Repository engineering structure for Git/GPT/DSH collaboration

Status: accepted
Date: 2026-09-30

## Decision

Define the long-term collaboration shape of the repository rather than keeping the pre-Git working-snapshot layout.

1. **Single repository root.** The Git repository root is the project workspace root. `Data/App` is not a nested repository.
2. **Tracked surface.** Git tracks `AGENTS.md`, the root launcher, and `Data/App/**` (source, docs, tests). Everything else under `Data/` — user replays, labels, machine-local settings, derived caches, diagnostics, runtime output, the `Legacy` snapshot and the old handoff document — is untracked and preserved on disk only.
3. **Three-layer test gates.** `Tests/Smoke-Fast.ps1` (daily default, includes the module-boundary structure gate), `Tests/Smoke-RealRegression.ps1` (real replay evidence, only for native parser / action / telemetry core changes), `Tests/Smoke-Full.ps1` (Fast + Real at stage closure). `Smoke-NativeFirstV3Composite.ps1` becomes a compatibility wrapper.
4. **Frontend split.** The former single-file frontend becomes `Modules/Frontend/index.html` + `css/app.css` + `js/app.js`, served by the existing loopback HTTP server. UI behaviour, startup path and business logic are unchanged; no framework is introduced.
5. **Default AI context.** `AGENTS.md` + `docs/STATUS.md` + `docs/ARCHITECTURE.md` + the task's own files + `git status` / `git diff`. No large handoff document, no per-version changelog, no chat transcript, no regenerated ZIP handoff.
6. **Privacy rule.** No real name, real email, user-profile path or machine name in Git-tracked content, commit messages, docs, logs or test fixtures. Absolute paths use `<PROJECT_ROOT>` / `<USER_HOME>` placeholders.

## Reasons

- Git provides line-level history and reviewable diffs; duplicating that in Markdown handoff documents repeatedly consumed AI context.
- A full real-replay regression on every small change is too expensive; the layered gates keep the default change loop cheap without weakening real evidence requirements.
- A 56 KB single-file frontend is a diff and token hotspot; splitting it makes local reading and review possible without changing behaviour.
- Collaborators (human, GPT, DSH) all read the same small set of files, so the shared truth is the working tree plus Git.

## Consequences

- The baseline commit is a clean current-state baseline, not a reconstruction of exploratory history (consistent with ADR 0001).
- Runtime and user data remain outside version control; a fresh clone contains source, docs and tests only, and derived caches rebuild from the user's own replays.
- Excluding `Data/Legacy/` from Git means retired V2 architecture is no longer visible to any agent reading the repository. (Amended 2026-09-30: the local copy was subsequently deleted as well, together with the old handoff document, after confirming that no production code referenced either path.)
- A full clone cannot reproduce a benchmark run without the user's replay archive; the real-replay gate skips with an explicit "not present" status rather than failing.
