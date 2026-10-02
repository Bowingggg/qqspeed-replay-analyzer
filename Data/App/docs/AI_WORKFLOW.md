# GPT + DSH collaboration contract

This is the repository-side contract only. DSH-specific model/plugin/MCP tuning is a later step.

## Shared state

The shared truth between GPT and DSH should be the working tree and Git diff, not a regenerated ZIP handoff package or a long chat handoff document.

Each work item should carry only:

- objective;
- relevant files/modules;
- constraints/authority rules;
- expected validation;
- current diff or commit range when reviewing existing work.

## Default roles

- **GPT**: architecture, task decomposition, difficult reasoning/research, review of diffs and test evidence.
- **DSH**: local repository inspection, implementation, Windows PowerShell execution, smoke tests and concrete evidence collection.

These are defaults, not hard capability boundaries.

## Context minimization

Start with `AGENTS.md` + `docs/STATUS.md`; add `docs/ARCHITECTURE.md` only when authority/architecture matters. Then open only the files touched by the task.

Do not attach or ingest the entire repository for every turn. Do not include `docs/research/` unless a concrete unresolved question requires it.

## Validation contract

- Fast Gate is the default: `Tests/Smoke-Fast.ps1`.
- Real Regression only for native parser / action / telemetry core changes: `Tests/Smoke-RealRegression.ps1`.
- Full Gate at stage closure: `Tests/Smoke-Full.ps1`.
- Report what actually ran. Never claim a smoke passed when it was not executed.

## Privacy

Never write a real name, real email, user-profile path or machine name into Git-tracked content, commit messages, docs, logs or test fixtures. Absolute paths use `<PROJECT_ROOT>` / `<USER_HOME>` placeholders.
