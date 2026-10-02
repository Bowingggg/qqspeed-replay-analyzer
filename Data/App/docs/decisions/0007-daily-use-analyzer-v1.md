# ADR 0007 — Daily-Use Analyzer v1: map coverage, settlement trust, Driving Analysis v2

Status: accepted
Date: 2026-10-01
Related: `0001` (native-first cutover), `0002` (repository structure), `0005` (native action production authority), `0006` (catalog lock)

## Context

After "Usable Native Analyzer v1" the native data was trustworthy but the product still conflated
three different things in one view: game-facing settlement numbers, raw native evidence, and
derived measurements. Three concrete symptoms:

1. **Map coverage.** The catalog build index matched `Map\Common Map\MapNN` with a case-SENSITIVE
   regex while the VFS reader and the descriptor parser were case-insensitive. Real archives
   contain `MAP08` / `map85` style folders, so 25 map ids (including `Map12 老街`) were dropped and
   16 of them had no catalog entry at all. Separately, tier 0 of the replay resolver
   (trusted room-catalog name → Game MapID → verified Resource binding) was skipped whenever the
   replay filename produced a display hint, so those resolutions lost `game_map_id` and were
   downgraded from `verified` to `high`.
2. **Settlement trust.** The UI showed `SystemDrift 28` next to `漂移 22`, and presented raw
   `code2001 46` as `漂移小喷 46`. Neither label was true: raw `code2001` is not a normal
   small-boost count, and the pre-coalescing drift interval count is not the game drift count.
3. **No per-corner value.** `driving_analysis` was a developer diagnostic
   (`L1 sections=8 samples=455 ... sigP95=...`) and, worse, an unresolved map identity made the
   whole driving analysis `unavailable`, so a replay without official map evidence had no training
   value at all.

## Decision

### 1. Map coverage is restored, not guessed

- The build-index path locator is case-insensitive, matching the VFS reader and descriptor parser.
- Tier 0 evidence is computed independently of the display hint: a filename hint may never suppress
  the higher-authority verified-binding route.
- The tier decision is extracted into `Get-ReplayMapResolutionDecision` (pure) so the contract is
  testable without the game installation or the archive.
- **`老街管道` stays unresolved.** `GameMapID 112` has no authoritative official name and no
  verified binding; the `+100` offset hint onto `Map12 老街` is explicitly non-authoritative, and
  near names (`老街仓库`/`老街车站`/`老街工地`) are not equal names. Correct handling is
  unresolved or a UI-only alias; guessing to make driving ready is forbidden.

Measured after the rebuild: catalog 451 → 467 map ids, verified bindings 228 → 231,
`unresolved_or_special` 19 → 9; the 12 archived replays go 8 resolved (all `confidence=verified`,
all with a recorded `game_map_id`) + 4 unresolved, exactly as before at the identity level.

### 2. Settlement trust is published as three separate things

Every action quantity is now published as **game-facing / raw native evidence / unresolved**, and a
game-facing number is only published where the native evidence closes against the gold replays.

- **Closed (game-facing):** air boost (`code8`), landing boost (`code9`),
  CW/WCW/CWW (`code19`/`code24`/`code25`), logical drift.
- **Raw only, parity unresolved:** `code2001` (small-boost class) and `code1` (nitro). The raw
  counts are published with `raw_evidence_status = native_fact`, proven by a per-code toggle-stream
  audit (open records == close records == interval count), and the game-facing count field stays
  `null` with `game_facing_count_status = unavailable_parity_unresolved`.
- `code2001` normal-small-boost parity is **still unresolved**. Rejected hypotheses (each with
  counts) are recorded in the contract: overlapping-pair collapse (Gold A would give 22 vs 27),
  nitro containment (14/27 vs 31/46), combo-marker collapse (10 vs 19), short-duration intervals
  alone (1 vs 11). The only surviving correlation — `duration <= 640 ms AND not exactly anchored on
  a code24` is 7 in Gold B and 0 in Gold A — reproduces the gap but has no identified native
  mechanism, so it is recorded as an **unpromoted correlation** and is not used as a rule.
- `nitro` parity is **still unresolved**. The `code1` toggle stream is strictly alternating and
  balanced in both gold replays, no interval reaches twice the nominal ~3283–3300 ms duration, and
  no action code lands on a `code1` interval start (0 of 724 archive-wide), so the surviving
  candidate is "one game use never opened its own effect interval" — with no independent native use
  marker. The `+1` is published as an observation, never as a computed count.

### 3. Replay variants fail closed

The archive-wide consistency test for the action event table is that codes `2/8/9/18/19/20/24`
land on (or 1 ms before) a `code2001` interval start. Two archived replays fail it completely —
`雪境裂渊-20260924-223202` (0/40) and `风林火山-20260924-224701` (0/45), both from the **same
2026-09-24 recording session** — and a constant time-base offset does not recover the relation
(best 4/45 @ +985 ms, 3/40 @ −1150 ms). They are treated as **replay variants**:
`status = production_semantics_variant_unvalidated`, `game_facing_available = false`, game-facing
counts withheld, raw native evidence still published. A stale telemetry summary written by an older
semantics contract is handled the same way (`production_semantics_contract_stale`).

### 4. Driving Analysis v2 = native episodes + measurement-only geometry

- **Native actions define the driving-event facts. Geometry is used only for position, distance,
  route difference and section measurement, and may never define Drift, Boost, Combo or an action
  type.**
- One **episode per logical native Drift action**, carrying identity, time, position, speed
  (entry/min/exit/loss/recovery), the associated native actions (raw interval count, air/landing,
  CW/WCW/CWW, nitro, `code2001`, unresolved markers) and exit-timing facts (drift end → first
  small boost / nitro / combo). Exit latencies are published as measurements, never as a
  good/bad judgement.
- Per-lap metrics: lap time, distance, average speed, logical drift count, total drift active time,
  and sum/median statistics for drift duration, entry/min/exit speed and speed loss.
- **Map-unresolved behaviour is split.** `native_episode_analysis` / `lap_metrics` /
  `native_driving_episodes` are map-independent and stay `ready`; only
  `spatial_driving` becomes `unavailable_prerequisite`. An unresolved identity no longer makes the
  whole driving analysis unavailable.
- Existing geometry sections stay the **spatial measurement container**; section v2 aggregates
  native-action measurements (logical drifts, total drift duration, CW/WCW/CWW/air/landing, boost
  latency statistics) onto them without changing section topology.
- Episode-to-lap assignment uses the replay-native `lap_index` of the drift-start row, so a drift
  spanning a lap boundary can never be double-counted or dropped, and
  `episode_count == logical drift count` holds on both gold replays.

## Reasons

- **The case-sensitive locator was a silent coverage defect, not a policy.** The VFS reader and the
  descriptor parser already accepted any case; the build index did not. A real catalog cannot be
  built from a subset of the game's map folders.
- **Tier 0 is strictly stronger than a filename hint.** Tier 0 requires a unique structured
  room-catalog MapID *and* an authoritative Game↔Resource binding; the filename hint is a raw
  string. Skipping tier 0 whenever a hint existed threw away the stronger evidence.
- **A number a user reads must be a number the evidence supports.** `漂移小喷 46` was wrong twice:
  raw `code2001` is not a normal small-boost count, and the count itself does not close. Publishing
  raw evidence with an explicit unresolved status is honest; subtracting 7 or adding 1 is not.
- **Variants must not pollute shared rules.** Two replays failing every native alignment diagnostic
  while 5 others pass at 1.000 is a schema/variant boundary, not a threshold to widen. Failing
  closed keeps the remaining replays' semantics meaningful.
- **A replay without a map identity still has training value.** Lap times, drift durations, entry
  and exit speeds and native combo counts need no map. Only spatial sectioning does.

## Consequences

- New modules: `Modules/MapCatalog/Catalog.Naming.ps1` (shared naming helpers, so the resolver is
  independently loadable), `Modules/Native/NativeDrivingEpisodes.ps1` (Driving Analysis v2).
- New Fast Gate regressions: `Smoke-MapResolutionTiers.ps1`, `Smoke-MapCatalogBuildCoverage.ps1`,
  `Smoke-NativeDrivingEpisodes.ps1`. New Real Regression additions: alignment/variant/toggle
  cases in `Smoke-ProductionNativeActionSemantics.ps1`, plus `Smoke-NativeDrivingEpisodesReal.ps1`.
- `telemetry_summary` schema 16 → 17 (`native_action_event_timeline`), analysis schema 23 → 24
  (`driving_episodes`, `driving_status`, `native_actions.statistics_contract`). The telemetry tool
  version is bumped so a pre-existing summary is not silently reused.
- `native_actions` gained `game_facing_available`, `semantic_alignment` and
  `statistics_contract`; the primary view shows logical/game-facing semantics and raw evidence moved
  to diagnostics. The misleading label `漂移小喷` is removed.
- Driver-insight scoring (0–1 drift efficiency as a product number, AI coaching, reference lines)
  remains **out of scope**; only descriptive, derived comparisons are published.
