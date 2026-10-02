# Native-First architecture

This document describes the **current** architecture and authority boundaries only. It is not an evolution history; use Git history for that.

## Core principle

Native/official facts are authoritative. Derived analysis can explain those facts but must not redefine them.

The production chain is:

`Replay -> Map Identity -> Telemetry -> Native Actions -> Official Native Map -> Native Driving -> Analysis -> Frontend`

## Authority boundaries

### Map identity

Every resource folder `Map\Common Map\MapNN\` carries its own identity record,
`LapDistanceFile.luc`, whose `mapId` field is the **game-side MapID** (the same namespace the room
selection table `uires\mapsel\maps.luc` stores as `mapid`) and whose `mapName` field is the
maintained display name. That record is the primary authority; the scene descriptor's
`map_desc.map_name` is a label the client does not keep in step and is never an identity name when the
resource declares a usable one. See `decisions/0014`.

Allowed authoritative routes:

- **resource-declared game MapID** (`MapNN LapDistanceFile.luc mapId`, tier 0): a direct structural
  GameMapID ↔ ResourceMapID statement. A game MapID declared by two folders is a conflict and fails
  closed as `ambiguous_declared_map_id`;
- verified GameMapID ↔ ResourceMapID anchor (tier 0, reached through a trusted room-catalog name);
- exact official name match (tier 1) against the catalog's identity names (the declared name when the
  resource declares one, otherwise the descriptor name);
- **user-confirmed GameMapID ↔ ResourceMapID binding** (tier 0, `confidence = user_confirmed`), used
  only when no official evidence exists and only ever written by an explicit human action.

Manual labels are display metadata only. Unresolved identity remains unresolved.

The observed `game_map_id = resource_map_id + 100` relation is **diagnostic only and not universal**
(it holds for every currently verified row, but the resource declarations contain counter-examples
such as `Map340 → game 414`), so it can never promote a row; unmatched rows stay
`offset_supported_candidate`.

A replay-filename display hint is display metadata. It may never suppress tier 0: the recorded `game_map_id` and `confidence=verified` are kept whenever the verified-binding route applies. A near or prefix name match (`老街管道` vs `老街`) is not an equal name and never promotes.

The user-confirmed route never outranks a verified/declared binding, is never created or inferred by
any build or analysis path, is stored as a user fact
(`Data\MapCatalog\user_confirmed_game_resource_bindings.json`, preserved by every derived rebuild and
cold reset), and is revocable. Every still-unresolved GameMapID used by the September corpus must be
recorded in `Modules/MapCatalog/Data/map_confirmation_required.json`, so an unresolved map is never
silent; the open set is currently empty because the last three rows are closed by their resource
declarations.

### Map geometry

Production basemap is official `Map/Common Map/MapNN/map.nif` in file-native world XY.

Supported reader families:

- standard Gamebryo AV layout;
- signature-gated QQSpeed 20.2.5.22 AV-marker layout (`qqspeed_20_2_5_22_av_marker_v1`);
- signature-gated QQSpeed 20.2.5.23 AV-tail layout (`qqspeed_20_2_5_23_av_tail_v1`).

Each modern profile is gated on its own version signature plus a hard marker/tag check, and any
mismatch fails closed. No replay-fit, rotation/scale/translation fitting, trajectory basemap or nearest geometry fallback is allowed.

### Replay motion

Production physical telemetry stream is authoritative for observed motion. For validated 2026 replay records, native linear velocity is the speed source.

**Physical stream detector contract v2** (`physical_streams_v2_nondec_ts`, `Modules/Telemetry/QQReplayTelemetry.Core.cs`).
A physical vehicle stream is a lane of fixed-stride records whose leading `u32` is the replay-native
millisecond clock. The contract has three layers:

1. **Structure.** A maximal run of consecutive records whose clock step satisfies `0 <= dt <= 100 ms`.
   A backward step always ends the run. The clock is **not** required to advance on every record: a
   networked opponent's clock is quantised to the local frame grid, so consecutive records legitimately
   repeat the same millisecond (measured zero-step ratio `0.00..0.27` across the corpus). Requiring
   `dt >= 5 ms` shredded those streams below `MIN_STREAM_RECORDS` and silently dropped the second car.
2. **Clock.** The run itself must really advance (`elapsed >= 2000 ms`), be driven by forward steps
   (`forward ratio >= 0.30`) and not be a frozen or constant-filled lane (`zero ratio <= 0.90`). A lane
   whose `time_start == time_end` therefore fails closed and can never become a vehicle.
3. **Geometry.** Dense validation over **every** record: quaternion norm in `0.80..1.20` for at least
   80 % of records, every position finite and in range, and an XY movement span `> 20` units. A slot
   whose clock advances but whose position does not move is rejected here.

Every threshold is derived from the real 2026 regression corpus; none is keyed on a file name, a SHA,
an offset, a residue or a cadence band. `low-frequency` describes the **sampling/source role**, never
visual quality: a smooth networked trajectory stays `network_low_frequency`.

Physical streams become logical shadows by grouping parts that are contiguous in time, compatible in
cadence and spatially continuous. `local_high_frequency` is the highest-cadence shadow; the remaining
shadows are `network_low_frequency` in deterministic order (`shadow_local`, `shadow_network_01`, ...).
Physical count and logical count are published separately.

### Shadow ownership

Motion, time, lap, speed and physical facts belong to whichever lane carried them. **Native semantics
belong to the local authoritative shadow only** unless the container proves a per-vehicle owner:

- The replay-native Drift/effect action objects are claimed per shadow by `count_offset`, and a shadow
  never re-claims an offset another shadow already owns.
- The replay-native action event table is decoded **once per replay** and carries no per-vehicle owner
  in the container. It is published only on the local shadow; every other shadow publishes
  `native_action_event_available = false`, `native_action_event_ownership =
  unavailable_non_local_shadow`, a null count, an empty histogram and an empty timeline. The decoder
  and the semantic resolution are not modified by this — only attribution is.
- A non-local shadow therefore keeps trajectory/time/lap/speed and its raw per-shadow Drift/effect
  evidence, and publishes no game-facing local action count.

### Drift / effects / actions

Drift comes from replay-native action-object Drift tables. Shift is diagnostic-only.

The Drift table contract (`replay_native_action_object_drift_table_v3`) is the **interval sequence**,
not the raw record order:

- records are `u32 time_ms; u8 state`, the state byte alternating `1,0` starting at `1`;
- consecutive record pairs are one interval, and the pair's two timestamps are that interval's
  boundaries **in either write order** (endpoints normalised to `(min, max)`);
- **interval starts never move backwards**;
- also required: even in-range count, times within `0..600000`, span ≥ 300 ms, and at least
  `max(1, floor(intervals/2))` non-zero-length intervals.

Authority is structural: a marker-linked native action object, or a structurally valid Drift table
directly paired with a valid adjacent native speed-effect table. A replay may contain several native
action-object blocks; the authoritative one is selected by the strength of that structural pairing
(largest adjacent effect table), and the block whose `code2001` effects align with the action event
table is the one the alignment gate accepts.

Speed effects come from replay-native action-object effect tables. Known semantic mappings are intentionally narrow; unknown codes remain unknown.

For automatic Drift analysis segments, **effect existence is not the same as recovery ownership**. A recovery tail may be extended only by a post-Drift `code2001` small-boost-class effect inside the bounded onset search. Standard Nitro/`code1` is independent propulsion evidence and is never allowed to extend a Drift segment; `code2003` map propulsion and unknown effects are excluded as well. If no eligible small-boost exists, the segment ends at the native Drift end. For an already-owned recovery tail, the first sustained replay-native `contact_state == 0` interval (>=100 ms) is a conservative **airborne hard cut**: automatic Drift analysis stops at take-off and leaves airborne/Nitro/landing continuation to Custom Path. The next independent Drift start remains the other hard cut; the earlier cut wins.

Current-Segment **metrics are deliberately separate from the shared A/B route window**. `entry_speed_mps` is anchored to that side's native Drift start; `min_corner_speed_mps` is measured only over that side's native Drift span; `exit_speed_mps` is the fastest measured speed from the final native Drift end through that side's own recovery metric end; and `recovery_distance_m` is the trajectory distance over that same own-side interval. Spatial correspondence decides the common comparison time window, but it cannot move these native-corner metric boundaries. A metric-only 0.25 s minimum small-boost tail may be used when native speed-effect state is unobservable (or a network-low-frequency shadow has no small-boost/nitro evidence). This is sourced from the game's `SetXiaoPen` lifetime and never changes segment ownership, map drawing, or the shared A/B interval.

For **paired-corner primary time**, the shared window is intentionally shorter than a full recovery union. The start remains the earlier mapped Native Drift start so an early/late entry choice is still measured; the end is the earlier mapped natural recovery end. Therefore a double-spray/longer recovery tail cannot extend the main efficiency interval after the other side has already completed its natural recovery. The excluded tail is not discarded: it remains visible through that side's own exit-speed, recovery-distance and total-distance metrics. Custom-path and unpaired-corner modes keep their own explicit window rules.

The paired contract also publishes a **final net window** with the same start and the later mapped natural recovery end, hard-cut by the next independent Drift of either side. `core_time` answers corner-handling efficiency; `final_time` answers the net time gap after single/double-spray recovery strategy; `recovery_strategy.subject_net_gain_s = core_delta - final_delta` explains how much A gained or lost between those boundaries. The map uses `final_time`; the inspector shows all three layers.

**Actions come from the replay-native Action Event Table** (production authority `replay_native_action_event`): `code8` = air boost, `code9` = landing boost, `code19` = WCW marker, `code24` = CW/WCW/CWW common marker, `code25` grouped with a `code24` = CW, remaining `code24` = CWW (`decisions/0005`).

The table is located by `replay_native_action_event_locator_v2`: the historical fixed point (the table ends exactly `trailer_bytes` = 374 bytes before the container end) is attempted first, and only when it has no solution does a bounded structural search run. The structural search is confined to the last `EofBound` bytes of the container, is anchored on the container's own `u32 count`, validates the whole `count * 12` record span forward (`reserved == 0`, `1..200` codes, non-decreasing times in `1..600000`), rejects a candidate whose own table start is preceded by another valid record, and fails closed on zero candidates (`unresolved`) or several maximal candidates (`ambiguous`). It never uses a per-replay offset, a replay SHA, a file name or the legacy timing detector. Which path was used is published as `locator_contract` / `locator_path` / `trailer_bytes_at_locator`, and the locator contract is part of `telemetry_semantic_signature`.

The published action contract carries **per-authority availability**: `action_event_table_available`, `drift_table_available`, `effect_table_available`. Consumers must gate a quantity on its own authority — an undecodable action event table may null only the action-event fields and must never null Drift or the raw effect evidence.

- Raw native Drift intervals are grouped into **logical** drift actions by native retrigger coalescing; both the raw and the logical count are published, and the raw evidence is never overwritten.
- Every action quantity publishes **raw evidence / logical-semantic count / unresolved evidence** separately. A game-facing count is only published where the native evidence supports it (air, landing, CW/WCW/CWW, logical drift); `code2001` normal-small-boost parity and nitro parity are explicitly `unresolved`.
- The timing-based combo detector (`ReplayNativeComboActions.ps1`) is a **diagnostic/disagreement** layer (`authoritative=false`). There is no fallback to it: if the action event table is unavailable, the action counts stay unavailable.
- The contact-state air/landing inference is kept as a diagnostic cross-check only.

### Driving sections

`native_driving_sections_v1` is derived, non-authoritative analysis over observed telemetry in official world XY.

Section topology is geometry-only. Native Drift/actions may annotate a section but must not create, expand or merge section boundaries.

Section v2 additionally aggregates native-action measurements onto each existing section (logical drifts, total drift duration, CW/WCW/CWW/air/landing, boost latency statistics). This adds measurement, never topology.

### Driving episodes (Driving Analysis v2)

`native_driving_episodes_v1` is derived, non-authoritative analysis.

**Native actions define the driving-event facts. Geometry is used only for position, distance, route difference and section measurement, and may never define Drift, Boost, Combo or an action type.**

- One episode per logical native Drift action, with identity / time / position / speed / native-action association / exit-timing facts.
- Per-lap metrics (lap time, distance, average speed, logical drift count, total drift active time, drift duration and speed statistics).
- Exit latencies (drift end → first native boost / nitro / combo marker) are published as measurements only; no good/bad judgement and no score.
- **Map independence is explicit.** `native_episode_analysis`, `lap_metrics` and
  `native_driving_episodes` need only production telemetry and the replay-native action tables.
  Only `spatial_driving` (official map / spatial sections / same-map A–B) requires an authoritative
  map identity. An unresolved identity must never make the native episode analysis unavailable.
- Episode-to-lap assignment uses the replay-native `lap_index` of the drift-start row, so
  `episode_count == logical drift count` and every episode belongs to exactly one lap.

### Training analysis (Training Analysis v1.1)

`native_training_analysis_v1` (`Modules/Native/NativeTrainingAnalysis.ps1`,
`NativeTrainingSections.ps1`, `NativeTrainingTimeLoss.ps1`) is derived, non-authoritative analysis. It
answers *where* lap time was won or lost instead of only *how much*.

**Measurement only.** No score, no grade and no coaching is produced. Every derived statement is
labelled `derived_observation`, states a measured time difference beside the co-occurring measured
differences, and carries `causation = "not asserted"`.

**One delta contract.** `delta = subject - baseline`, everywhere: lap totals, comparison windows,
matched and unmatched windows, non-comparison stretches, residuals, speed, drift duration, boost
latency, route distance, observations, JSON and the interface. `delta > 0` means the subject is
slower (time loss); `delta < 0` means it is faster (time gain). `top_loss_sections` holds only
`delta > 0` ranked descending and `top_gain_sections` only `delta < 0` ranked by magnitude
descending - loss and gain are never mixed. Swapping subject and baseline negates every signed
metric, which is pinned by a regression.

Three levels degrade independently:

| level | capability | depends on |
| --- | --- | --- |
| 1 | Lap analysis | production telemetry only; **map-independent** |
| 2 | Native driving episode v2 | the replay-native Drift table; **map-independent** |
| 3 | Shared spatial comparison / same-map A/B | an **authoritative** map identity; A/B additionally needs two replays with the **same** official `ResourceMapID` |

**Shared spatial correspondence.** Two laps or two replays are compared through one monotonic,
order-preserving, heading-compatible, bounded and fail-closed correspondence built from the two
**real driven trajectories** in official world XY (sample order + local spatial distance). There is
no reference line, no CanonicalTrack, no TrackTopology, no synthetic centre line and no template
route in that step, and **time is deliberately excluded from its cost**: a slower replay must never
align onto a different position because it passes later. A region with no admissible counterpart
stays unmatched; the correspondence may not be forced to full coverage.

**Shared comparison windows.** The correspondence defines a shared progress, and ONE boundary set is
built on it from the union of both sides' section boundaries. Both sides therefore measure the same
windows instead of each sectioning its own course and being paired afterwards. Each window publishes
its own subject/baseline time, distance, entry/min/exit/average speed, native Drift facts and boost
latency, plus the correspondence status of that stretch.

**Same-map A/B is fail-closed.** A different, unresolved or non-authoritative `ResourceMapID`
produces `comparison_unavailable` with no breakdown and no loss sections.

**Delta reconciliation is published.** Every comparison reports
`total_delta = matched_delta + unmatched_delta + non_comparison_delta + residual`. The residual is
the measured difference between the two ways of measuring the same laps - the comparable stretches
are sub-sample interpolated while a non-comparison stretch is published as a whole telemetry-row
span - so the tolerance is **derived** from the number of non-comparison boundaries and the stream's
own sample interval, never chosen for looking comfortable. A residual above that tolerance is
reported `degraded_residual_exceeds_tolerance`, a correspondence below the coverage minimum is
`degraded_low_correspondence_coverage`, and a comparison with no shared window publishes every sum
as `null`.

### Product statistics contract

`product_statistics_contract_v1` (`native_actions.statistics_contract`) is the single place that declares what a user-facing number means.

- **Primary (game-facing)** numbers are only published where the native evidence closes against the gold replays: logical drift, air boost, landing boost, CW/WCW/CWW.
- **Raw only** evidence keeps its raw label and an explicit unresolved status: `code2001` small-boost class intervals, `code1` nitro intervals, pre-coalescing drift intervals, unknown action codes.
- **Unavailable** fields (`普通小喷` settlement count, `氮气次数` settlement count) stay `null` with a reason; raw evidence is never renamed into a game-facing label.

### Native action semantic alignment (replay variants)

The action event table may only publish game-facing counts when codes `2/8/9/18/19/20/24` land within 2 ms of a `code2001` interval start.

- Aligned archived replays measure 1.000 (9/9, 22/22, 32/32, 36/36, 37/37).
- Two archived replays (`雪境裂渊-20260924-223202`, `风林火山-20260924-224701`) measure 0.000 and a constant time-base offset does not recover the relation, so they are replay **variants**.
- A variant fails closed: `game_facing_available = false`, game-facing counts withheld, raw evidence published. A telemetry summary written by an older semantics contract is treated the same way (`native_contract_stale`).

### A/B

Section pairing and continuous comparison are descriptive only. They compare observed routes in official world XY and never construct a canonical/reference/ideal line.

## Persistent transport/evidence caches

### PhysicalTelemetryCache

`qpf_v2_nondec_ts_2026schema1_fastpipe1` is a source-SHA + decoder-contract + **detector-contract**
validated transport cache. It changes transport cost, not semantic authority.

The descriptor binds the detector explicitly through a required `detector_contract` field
(`physical_streams_v2_nondec_ts`). A descriptor written by an older detector carries no such field, so
it fails closed and is rebuilt on the next run — a detector change can never be masked by a stale cache
that still looks structurally valid, and the user never has to clear derived data by hand. The script
constant and the loaded C# contract identity are cross-checked at start-up; a mismatch throws instead of
writing a cache that describes a different detector.

### NativeActionCache

`native_action_cache_v1` stores raw native action tables plus the exact raw tail window scanned from the replay. It stores no semantic labels. Semantics are re-derived from current code. Its scanner contract is `replay_native_action_suffix_scan_v2`; a contract mismatch re-parses the persisted raw tail instead of re-reading the SAV.

The two caches have independent lifecycles. A **derived** rebuild never clears them; a *true cold*
acceptance reset does (`Reset-QQReplayDevelopmentDerivedData -IncludeValidatedCaches`), because a cache
hit must never be usable as evidence about parser coverage.

### Derived telemetry summary (shadow) cache

The telemetry writer short-circuits when `telemetry_summary.json` already exists, which makes the
summary a third, implicit cache. It may only be reused when a `telemetry_semantic_signature` composed
from the parser contracts (`native_action_event_table_v1`, `production_native_action_semantics_v1`,
`replay_native_action_suffix_scan_v2`), the **physical stream detector contract**
(`physical_detector`, `raw_cache`) and the derived schema revisions (`schema`, `drift_tl`,
`effect_tl`) is unchanged. A summary without that signature fails closed and is rebuilt; `-ForceRaw`
bypasses the guard.

The detector contract is part of the signature because it decides how many logical shadows an already
written summary describes: without it a detector change would keep serving the old stream count.

Changing a decoder contract means bumping its contract constant; changing the **shape** of the summary
means bumping `$script:TelemetrySchemaVersion`. Changing the **physical stream detector** means bumping
`$script:PhysicalDetectorContract` (and the `detector_contract` binding in `$rawCacheContract`). All
three invalidate the derived layers automatically.

## Frontend runtime and first-run bootstrap

The local web frontend remains a loopback-only Windows PowerShell service. Runtime/UI helpers are
transport concerns and never add semantic authority.

- A clean install requires only a valid QQ飞车 game directory. If either `MapCatalog/map_index.json`
  or `MapCatalog/game_resource_bindings.json` is missing/unusable, the frontend starts one background
  bootstrap task that runs the official catalog build followed by the GameMapID↔ResourceMapID binding
  build. Existing ready catalog data is never rebuilt implicitly on ordinary startup.
- `添加录像` is gated until first-run bootstrap is ready, and the analysis endpoint fails closed if a
  caller bypasses the UI while initialization is incomplete.
- Explicit catalog reinitialization uses the same background task path; it must not block the HTTP
  listener for the several-minute catalog scan.
- Segment comparison uses a bounded six-entry process-local cache of typed telemetry CSV rows. Cache
  validity is transport-only and bound to the CSV full path, byte length and `LastWriteTimeUtc`; stale
  entries are re-read automatically and destructive runtime-cache operations clear the process cache.
- Visual pan/zoom/hover/selection are canvas redraws only. They may not rebuild the view model or rerun
  spatial correspondence.

The listener still services one request at a time. Replay analysis itself is currently synchronous, so
a long analysis can delay unrelated UI requests; that is a known responsiveness limit, not an analysis
contract.

## Capability levels and the unavailable/zero contract

Product capability degrades independently per level:

| level | capability | depends on |
| --- | --- | --- |
| 1 | Physical + **Basic Driving** (duration, distance, average and max speed, sample rate, frame count, lap count) | production telemetry only |
| 2 | Native actions | replay-native action event table |
| 3 | Native Drift / logical drift / episodes / lap metrics | replay-native Drift + effect tables |
| 4 | Official map | authoritative map identity + official `map.nif` |
| 5 | Spatial driving (sections, same-map A/B) | level 4 + level 1 |

An unresolved map identity leaves levels 1–3 ready and only makes level 5
`unavailable_prerequisite`.

**`unavailable` is not `0`.** Every gated quantity publishes its own availability flag, and a count
derived from a table that was never decoded is `null` (`N/A` in the interface). `0` means "resolved
and measured as zero" — for example a structurally validated Drift table with no intervals.
`Smoke-September2026ReplayReadiness.ps1` asserts this for every corpus replay.

**Availability never propagates across capabilities.** A level-2 failure (the action event table could
not be decoded) may withhold air / landing / CW / WCW / CWW and the unknown action codes, and nothing
else: level 3 Drift / episodes / lap metrics and the raw speed-effect evidence keep being published
from their own native tables. Two gates pin this — `Smoke-CapabilityIndependence.ps1` (Fast, synthetic)
and `Smoke-Current2026Closure.ps1` (Real Regression) — and the published contract carries
`action_event_table_available` / `drift_table_available` / `effect_table_available` so a consumer can
never re-conflate them.

A map that cannot be resolved automatically is either **auto-ready**, **pending user confirmation**
(every such GameMapID is recorded in `Modules/MapCatalog/Data/map_confirmation_required.json`) or, if
it is in neither, a gate failure. Pending is never counted as ready.

## Forbidden production fallbacks

- trajectory basemap
- MapMatcher
- TrackTopology
- CanonicalTrack / reference line
- heuristic drift
- effect timing guess
- ReplayFingerprints

These are not production authority and must not be introduced as convenience fallback.

## Runtime data policy

Pre-release development rebuilds may destructively rebuild derived outputs. Raw replay archive and validated persistent transport/evidence caches are preserved according to `Modules/Replay/Replay.DevRebuild.ps1`.

