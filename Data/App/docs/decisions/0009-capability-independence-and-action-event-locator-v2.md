# 0009 — Capability independence and the Action Event locator contract v2

Status: accepted (Current-2026 Replay Closure v1)

## Context

The September-2026 readiness milestone declared that product capability degrades independently per
level, and that `unavailable` is not `0`. A user then randomly verified four real 2026-09 replays and
exposed two gaps that the earlier milestone's own corpus had not covered:

1. `320冒险岛-20260928` carried a structurally validated replay-native Drift table
   (**54 raw intervals -> 37 logical drift actions**) and a valid speed-effect table (43 `code2001`,
   24 `code1`), yet the interface showed `漂移 = N/A`. Its **action event table** did not decode, and
   the analysis layer used the action event table's availability as the gate for *every* native
   quantity, so the successfully parsed Drift result was published as `null`.
2. That same replay's action event table was in fact present, structurally valid
   (`u32 count = 65`, `reserved == 0`, monotonic times, production action-event codes) and
   **semantically aligned 30/30 = 1.000** with the local stream. It did not decode because
   `native_action_event_table_v1` located the table from a fixed point on `file_length - 374` — "the
   table is the last table, followed by a 374-byte SAV trailer" — and this recording appends **659**
   bytes of recording/session metadata after the table, with the table start also off the file-length
   byte phase (`count_offset % 4 == 1`, `file_length % 4 == 0`).

A third, non-parser gap surfaced with it: `里约奥运会` (GameMapID 325) resolved to *silently*
unresolved rather than to a recorded open question.

## Decision

### 1. Availability is per native authority, never global

Each capability is gated by the availability of **its own** native authority:

| capability | authority |
| --- | --- |
| Physical / Basic Driving | production telemetry |
| Action Event fields (air / landing / CW / WCW / CWW / unknown codes) | replay-native action event table |
| Drift / logical drift / episodes / lap metrics | replay-native action-object Drift table |
| raw `code2001` / `code1` evidence | replay-native speed-effect table |
| Official map / spatial driving | authoritative map identity + official `map.nif` |

An undecodable action event table may therefore null **only** the action-event fields. The published
contract gains explicit `action_event_table_available`, `drift_table_available` and
`effect_table_available` flags, and every quantity carries its own `available` / `game_facing` flag. A
consumer must read the flag that belongs to the quantity it renders; the table-level `available` means
"the action event table decoded" and nothing else.

The interface action panel previously required `production_actions.available === true` before showing
any production number, which nulled Drift for the same reason; it now reads per-field flags.

### 2. `replay_native_action_event_locator_v2`

The 374-byte fixed point is attempted **first**, so no replay that already resolved can change
behaviour. Only when it has no solution does a bounded structural search run:

- **bounded region** — candidate count offsets are confined to
  `[max(VisibleStart, FileLength - trailer_bytes - 4 - 12*MaxRecords), FileLength - trailer_bytes - 4]`;
  the trailing metadata region is never scanned without that bound, and a windowed read costs the same
  as a whole-file read;
- **anchored on the container's own count** — the count is read, never guessed, and the whole
  `count * 12` span must fit;
- **forward shape validation** — every record must be `{u32 time_ms; u32 action_code; u32 reserved}`
  with `reserved == 0`, `1 <= action_code <= 200` and non-decreasing `time_ms` in `1..600000`; the
  trailing length must stay within `EofBound` (8192) bytes;
- **a shifted view is rejected** — a candidate is discarded when the 12 bytes immediately before its
  table start are themselves a valid record, because then the declared count does not describe the
  whole record region;
- **fail closed** — zero candidates -> `action_event_count_unresolved`; several maximal candidates ->
  `action_event_count_ambiguous`. No per-replay offset, no SHA or file-name special case, no fallback
  to the legacy timing combo detector.

`locator_contract`, `locator_path` and `trailer_bytes_at_locator` are published, and the locator
contract is part of `telemetry_semantic_signature` so a summary produced by the old locator is rebuilt
rather than reused.

Measured: 18 of 19 closure-corpus replays still resolve through the fixed point; exactly one
(`43067EE8573EA091`) needs the structural path, where it yields `count = 65` at offset `4967797` with
`trailer_bytes_at_locator = 659` and passes the semantic-alignment gate 30/30.

### 3. An unresolved map is never silent

Every GameMapID that the corpus leaves unresolved must be recorded in
`Modules/MapCatalog/Data/map_confirmation_required.json`; `Smoke-MapCoverage.ps1` and
`Smoke-September2026ReplayReadiness.ps1` fail on an unrecorded one. `GameMapID 325 里约奥运会` was
added: the official resource catalog holds **two** rows with that exact primary name (Resource 225 and
Resource 226), the `+100` relation points at 225 while 226 is already the offset-supported candidate
for a different GameMapID (326), and `ReplayData.meta.map_id` is not an authority — so any automatic
choice would be a guess.

## Consequences

- A User-Confirmed binding remains the only path from a pending row to a map; pending is never counted
  as ready, and the product metric publishes auto-ready / pending / unresolved separately.
- The cost model is unchanged for replays that resolve through the fixed point; the one replay that
  needs the structural path pays ~0.6 s.
- `Test` regressions: `Smoke-CapabilityIndependence.ps1` (Fast, synthetic) and
  `Smoke-Current2026Closure.ps1` (Real Regression, real replays + the locator's v1 no-regression
  controls).
- The action event table's trailing layout is still not fully characterised (why some recordings append
  a 659-byte metadata block instead of the fixed 374-byte trailer is undecoded). The locator is
  structural and fail-closed, so this is a recorded limit, not an unsound assumption.
