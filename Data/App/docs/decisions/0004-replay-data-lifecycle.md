# ADR 0004 — Replay data lifecycle: Source / Catalog / Derived

Status: accepted
Date: 2026-10-01

## Decision

Separate three things that were previously one object, and forbid deriving intent from file presence.

```
Source Store    Data/ReplayArchive/<sha16>/<name>.sav + archive.json
                content-addressed, immutable, append-only.
                Presence means only "we still have the bytes".

Replay Catalog  Data/ReplayCatalog/replay_catalog.json
                the user's active logical replay set.
                state = active | removed, keyed by sha256.

Derived Store   Output/ Telemetry/ PhysicalTelemetryCache/ NativeActionCache/
                ReplayResolution/ NativeMaps/ NativeIdentity/ Diagnostics/
                entirely rebuildable. Presence means nothing about intent.
```

```
Source exists  !=  Replay active  !=  Derived exists
```

Hard rule: **no code may use "a .sav exists in ReplayArchive" as evidence that a replay
should be analysed.** The only operation that activates a replay is an explicit user import.

## Behaviour

| Operation | Effect |
| --- | --- |
| Import C | archive source, catalog upsert `C = active`, analyse **C only**. Never touches A/B. |
| Refresh ("重构数据") | heavy rebuild, but of **active** entries only. Never enumerates the archive for work. |
| Clear runtime cache | deletes caches and derived output. Does not change catalog or source. Does not rebuild. |
| Clear analysis data | deletes derived output. Catalog state unchanged; `active + derived absent` is a legal state. |
| Delete analysis | deletes that replay's derived output **and** sets catalog `removed` (source kept). |
| Re-import a removed replay | explicit user action, so `removed -> active`, `removed_at -> null`. |
| Metadata reconcile | may update `source_present` / `source_rel_path` / `size_bytes` only. **Never changes state.** |

## Catalog bootstrap

On first creation the active set is taken from the analyses that currently exist (the user's
visible list), never from the Source Store. Sources with no analysis become `removed`.
Ambiguity (missing `archive.json`, unreadable analysis, analysis without source) is reported and
left `removed`; nothing is guessed or auto-activated.

## Reasons

- **The resurrection bug.** `QQReplayRefresh.ps1` derived its work queue from the contents of the
  permanent source store, then wiped derived data and re-analysed everything. Because the source
  store is append-only, every refresh deterministically regenerated derived data for every replay
  ever imported — including replays the user had deleted. Measured before the fix:
  `refresh must not analyse any replay, but analysed: replayA.sav, replayB.sav, replayC.sav`.
- **Deleting an analysis could not stick**, because nothing recorded intent independently of the
  derived files.
- **Bootstrap must not repeat the bug.** Activating everything present in the store would just move
  the defect into a new JSON file.

## Consequences

- An explicit, separately-labelled operation is still required to rebuild a replay whose derived
  data was cleared: re-import it, run the analyzer for it directly, or use "重构数据" (which rebuilds
  all currently-active replays). No UI change was needed for this.
- The catalog is local runtime state, not source: `Data/ReplayCatalog/` is gitignored.
- No database, no new runtime dependency: one hand-written JSON file, atomically replaced.
- Cache invalidation is unchanged and stays strict: contract + source identity only, never a
  migration or a fallback for old derived data.
