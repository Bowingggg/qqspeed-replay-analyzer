# 0008 — Current-replay readiness: cold evidence, Drift interval contract, cache invalidation

Status: accepted (September 2026 Replay Readiness Gate)

## Context

The product could report a fresh 2026-09 replay as "fine" purely because stale derived artifacts
existed, and random recent replays came out as `Drift = 0`, `Map unresolved` or an empty page. A
mandatory acceptance corpus of real September-2026 `.sav` files was placed in `replay\` and the gate
was defined as: current 2026-09 replays must resolve map identity, produce the official map, resolve
native Drift and the supported native actions, and produce Basic Driving — starting from a true cold
state, without faking `unavailable` as `0`, and without a performance regression.

## Decision

### 1. Cold evidence is a first-class mode, not a side effect

`Reset-QQReplayDevelopmentDerivedData` keeps its frozen daily-use contract (a derived rebuild never
clears the validated `PhysicalTelemetryCache` / `NativeActionCache`). A new explicit switch,
`-IncludeValidatedCaches`, performs the **true cold** reset used for replay-readiness acceptance and
for any claim about parser coverage.

Reason: a cache hit must never be usable as evidence of parser coverage. Coverage claims are only
valid when the validated caches were cleared first.

### 2. The Drift table contract is the interval sequence, not the raw record order

`replay_native_action_object_drift_table_v3` records are `u32 time_ms; u8 state`, state alternating
1,0 from 1. The contract is now:

- consecutive record pairs are one Drift interval;
- the pair's two timestamps are that interval's boundaries **in either write order** (endpoints are
  normalised to `(min, max)`);
- **interval starts never move backwards** (a monotonic interval sequence);
- unchanged: even in-range count, state alternation, `0 <= t <= 600000`, span ≥ 300 ms, and at least
  `max(1, floor(intervals/2))` non-zero-length intervals.

Measured basis (15-replay September corpus): 3 replays carry exactly **one** inverted boundary pair
each and 12 carry none; **zero** replays violate non-decreasing interval starts. The old rule required
the raw record times to be non-decreasing, which is exactly "ordered pairs + non-overlapping
intervals".

Why this matters beyond hygiene: every replay contains several native action-object blocks. The
authoritative one is the one whose `code2001` intervals align with the action event table. Rejecting
the newest block made production fall back to a stale block, which then failed the code2001
alignment gate and silently withheld all game-facing action counts as a "replay variant".

Rejected alternative: forking a `native_drift_table_v2`. The two cases are **structurally
indistinguishable** at detection time — same container, same stride, same state encoding — so a
second decoder would only encode a data difference as a layout difference. The correct fix is one
decoder with the true invariant.

### 3. A derived telemetry summary may only be reused when every contract that decides its content
is unchanged

`QQReplayTelemetry.ps1` short-circuits when `telemetry_summary.json` already exists. That guard used
to compare only `extractor_version` and the source SHA, so a native-parser change kept serving the
old summary — the "an old cache makes it look fine" failure mode.

The guard now compares a `telemetry_semantic_signature` composed from the parser contracts
(`native_action_event_table_v1`, `production_native_action_semantics_v1`,
`replay_native_action_suffix_scan_v2`) plus the derived schema revisions (`schema=18`,
`drift_tl=4`, `effect_tl=2`). A summary without a signature fails closed and is rebuilt.
`-ForceRaw` now also bypasses the guard (previously it was a no-op when a summary existed).

Consequences that must be respected when changing the pipeline:

- any change to a decoder contract bumps its contract constant (which auto-invalidates the caches);
- any change to the **shape** of the summary bumps `$script:TelemetrySchemaVersion`;
- `NativeActionCache` scanner contract v2 marks the Drift rule change, so v1 caches are re-parsed
  from the persisted raw tail rather than reused.

### 4. User-confirmed Game→Resource binding is the only allowed escape hatch for map identity

Where the official resources contain no authoritative evidence (no exact `map_desc.map_name`, no
verified anchor), production stays unresolved. `user_confirmed_game_resource_binding_v1` adds a
persistent, explicitly human-confirmed mapping:

- stored as a **user fact** (`Data\MapCatalog\user_confirmed_game_resource_bindings.json`) beside the
  other manual user data; preserved by every derived rebuild and by the true cold reset;
- only an explicit action writes it
  (`QQSpeedMapCatalog.ps1 -Mode UserBinding -UserBindingAction confirm|revoke|list`); nothing in the
  build path may create it, and it is never inferred from a near name, the observed
  `game_map_id = resource_map_id + 100` relation, or replay geometry;
- it resolves at tier 0 but is reported with `confidence = user_confirmed`, never `verified`, and a
  verified binding always outranks it;
- every still-unresolved GameMapID must be recorded in
  `Modules/MapCatalog/Data/map_confirmation_required.json`, so "unresolved" always carries a named
  reason and a user action instead of being silent.

### 5. One additional official NIF reader profile, signature-gated

`qqspeed_20_2_5_22_av_marker_v1`: version `0x14020516` uses the same AV struct and the same one-byte
marker as `0x14020517`, without the `uint32 23` tag that `20.2.5.23` appends.

Verified by byte-for-byte comparison of two 5-block, Unity-exported official eagle maps
(`Map329` 20.2.5.22 vs `Map348` 20.2.5.23): the blocks are identical apart from that one `uint32`,
and dropping it makes the NiTriShape geometry reference resolve to the `NiTriShapeData` block, the
NiNode child list resolve to the NiTriShape, and both blocks reproduce the same trailing byte count.
`Map329` then decodes to 1386 vertices / 1490 triangles, `XY` projection, thickness ratio 0.029, and
100 % of the replay's telemetry positions fall inside the official geometry bounding box. The marker
byte is still a hard gate: any other value fails closed.

### 6. Unavailable is not zero

Every gated quantity publishes its own availability flag, and a count derived from a table that was
never decoded is `$null`. `0` means "resolved and measured as zero" (for example a validated empty
Drift table). `Resolve-ReplayNativeActionSemantics` now takes `-DriftTableAvailable` /
`-EffectTableAvailable`, the analysis layer nulls every count behind a false availability flag,
`basic_driving` is a declared Level-1 capability, and the frontend renders `N/A` instead of `0` where
a value is absent.

## Consequences

- Adding a decoder contract or changing a summary shape now invalidates downstream caches
  automatically; forgetting to bump is the only way to reintroduce a stale-evidence bug.
- `Smoke-September2026ReplayReadiness.ps1` and `Smoke-MapCoverage.ps1` make the corpus a real
  regression gate; `Smoke-UserConfirmedBinding.ps1` pins the confirmation contract.
- Legacy replay compatibility (for example 2021 replays) is explicitly out of scope and remains
  fail-closed.
