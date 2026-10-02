# ADR 0001 — Native-First clean Git baseline

Status: accepted  
Date: 2026-09-30

## Decision

Use the v3.7.0 Native-First production chain as the clean Git baseline instead of preserving the exploratory patch-by-patch source tree as active repository content.

The active tree removes patch-level changelogs, obsolete architecture tests/probes and ZIP handoff helpers. Durable research evidence is retained as cold context only.

## Reasons

- Production authority is already fully expressed by the Native-First chain; migration code is not part of the target repository model.
- Patch-level history was much larger than the current-state documentation and repeatedly consumed AI context.
- Git will provide line-level history and diffs after cutover; duplicating that history in hundreds of Markdown files is counterproductive.
- A small current-state contract is easier for both humans and coding agents to verify.

## Consequences

- The first Git commit is intentionally a clean baseline, not a faithful reconstruction of every exploratory patch.
- Detailed pre-Git evidence is cold context under `docs/research/` and is opened only for a concrete evidence question.
- Historical evidence under `docs/research/` does not grant production authority to any forbidden fallback.
