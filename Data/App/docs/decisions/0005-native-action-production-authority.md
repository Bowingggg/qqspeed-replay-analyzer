# ADR 0005 — Replay-native Action Event Table as the production action authority

Status: accepted
Date: 2026-10-01
Supersedes: the "candidate semantics stay non-authoritative" decision of `0003` (the decoder contract of `0003` stands unchanged)

## Decision

1. **Promote the replay-native Action Event Table to the production authority for air boost, landing boost and CW/WCW/CWW.** Production owner: `Modules/Telemetry/ReplayNativeActionSemantics.ps1`, authority string `replay_native_action_event`. Analysis, telemetry summary and frontend read that authority; the legacy timing combo detector becomes a diagnostic/disagreement layer only (`authoritative=false`, no fallback).

   | native code | production semantic |
   | --- | --- |
   | `8` | air boost |
   | `9` | landing boost |
   | `19` | WCW marker |
   | `24` | CW/WCW/CWW common combo marker |
   | `25` grouped with a `24` | CW |
   | remaining `24` | CWW |

2. **Every threshold is evidence-bounded and carries its evidence string in the output.**
   - `code25`/`code24` grouping: `|Δt| <= 500 ms` **and** no `code24`/`code19` record strictly between the two events. Largest accepted gap 283 ms, smallest rejected standalone gap 850 ms.
   - Logical drift grouping: both intervals `<= 500 ms` **and** gap `<= 100 ms`. Merged run = 7 intervals (417..16 ms, gaps 0..67 ms); shortest interval that must stay separate 600 ms, smallest such gap 217 ms.
   - Anchor tolerance `<= 2 ms` for `code2001` alignment (observed 0..1 ms in both gold replays).

3. **Settlement parity is published as separate values, never invented.** `raw evidence / logical-semantic count / unresolved evidence` are always distinct fields. Air, landing, CW/WCW/CWW and logical drift close against the gold replays; `code2001` normal-small-boost parity and nitro parity are published as `game_facing_parity = unresolved` with the raw native count unmodified.

4. **Unknown action codes stay unknown.** Every code without production semantics is published verbatim together with a per-replay evidence-matrix row (count plus how many occurrences land exactly on a `code2001`/`code1`/Drift start/end/`code24`/`code8`/`code9` anchor).

5. **The windowed decoder contract is explicit.** `Get-ReplayNativeActionEventTable` accepts `-BufferOffset`/`-FileLength`, so a caller can decode from a container window while every reported offset stays absolute; a window that does not reach the container end or does not cover the locator's whole search range fails closed (`action_event_window_does_not_reach_container_end`, `action_event_window_too_small`). Windowed and whole-file decoding are proven byte-identical by regression.

## Reasons

- **The table reproduces the human/game truth exactly in both gold replays** for air (5/5, 3/3), landing (4/4, 1/1) and CW/WCW/CWW (3/3/4 and 5/6/8). No timing heuristic is involved in the decision.
- **Native record adjacency alone is provably insufficient for CW.** In Gold B, `code24 #70` (t=121620) and `code25 #71` (t=122470) are consecutive records, yet the human count requires them not to pair (850 ms). A single tolerance is therefore necessary, and the observed gap (283 ms accepted vs 850 ms rejected) bounds it without invention.
- **`code25` raw count is not a CW count.** Gold B has 10 raw `code25`, 5 paired, 5 standalone; a raw-count interpretation would over-report CW by 2x.
- **The legacy detector is measurably wrong on the same replays** (Gold A 2/3/1 and Gold B 1/4/8 against 3/3/4 and 5/6/8), so keeping it authoritative would ship wrong numbers. Keeping it as a disagreement signal preserves its diagnostic value without letting it define production output.
- **Parity must not be faked.** Gold B has 46 `code2001` intervals against 39 game-reported actions, and the game nitro exceeds the native `code1` interval count by exactly one in both replays. Publishing raw/classified/unresolved (and `unresolved` parity) is honest; adding a hidden `+1` or subtracting 7 would be untraceable.

## Consequences

- New module `Modules/Telemetry/ReplayNativeActionSemantics.ps1` (definition-only) plus a new Real Regression gate `Tests/Smoke-ProductionNativeActionSemantics.ps1` (synthetic window/threshold contracts + pinned gold replays).
- `QQReplayTelemetry.ps1` decodes the action event table once per replay (from the NativeActionCache tail window on a warm run) and publishes `production_actions` per stream plus a contract block in `telemetry_summary.json`; the tool version was bumped because the summary contract changed.
- `NativeAnalysis.ps1` exposes `native_actions.actions` (per-quantity raw/logical/unresolved + authority) and keeps the older flat fields for schema compatibility, with the new authority explicit.
- The frontend reads the production fields; legacy/raw-code/disagreement detail stays in the diagnostics panel.
- `777` remains without semantics: the two gold replays do not contain it, so no production claim is made.
- `code2001` and nitro parity stay open problems; the published split is the starting evidence.
