# 0015 — Multi-shadow physical stream contract: a non-decreasing replay clock, and shadow ownership

Date: 2026-10-02
Status: accepted
Supersedes nothing. Related: `0004` (replay data lifecycle), `0005` (native action production
authority), `0009` (capability independence), `0014` (resource-declared map identity).

## Context

A QQSpeed replay can contain several vehicles at once: the local player plus every networked opponent.
Each vehicle is its own physical stream of fixed-stride `230`-byte records whose leading `u32` is a
millisecond clock.

The detector required every single step to satisfy `5 <= dt <= 100 ms`. That is true for a local 60 Hz
stream but false for a networked opponent, whose clock is **quantised to the local frame grid**: two
consecutive records can legitimately carry the same millisecond. Measured on the real corpus, the
zero-step ratio of a networked stream is `0.00 .. 0.27` (sparse on `VANS机场-20260925`, dense on
`熔岩古墓` / `TROY` / `风林火山`).

Each `dt == 0` step ended the run. The fragments then fell below `MIN_STREAM_RECORDS = 80` and the
opponent vanished. Measured consequences on the real corpus, before this decision:

| replay (sha16) | before | after |
| --- | --- | --- |
| `0A6C2D1AE550176F` `VANS机场-20260915` | 1 physical / 1 logical | **2 / 2** |
| `18755159E22FBFC6` `熔岩古墓` | 1 / 1 | **5 / 2** |
| `E851917C3D070EB1` `TROY-零号试验场` | 1 / 1 | **6 / 2** |
| `78A41115688EDA8D` `风林火山` | 1 / 1 | **3 / 2** |
| `EFDBE97299EA856A` `城市网吧` | 20 / 16 (all fragments) | **3 / 3** |

At the same time the mirror-image defect existed: because the strict predicate could also *keep* one
fragment that the relaxed predicate correctly rejects, an **inactive parked slot** was promoted to a
logical shadow. `43067EE8573EA091` published 8 logical shadows, one of which (`shadow_network_03`) was
266 records with `distance = 19.085` at the same `30.303 Hz` as a real opponent. Its records measure a
`6.3 .. 12.0` unit XY excursion over `3.5 .. 5.5 s` (clock `posRatio = 1.0`) — an advancing clock with no
movement at all.

The stage brief also required that a networked opponent must not silently inherit the **local** player's
game semantics. The replay-native action event table is decoded once per replay and the container
carries no per-vehicle owner for it, so publishing it on every shadow claimed an ownership the data does
not support.

## Decision

**1. The physical stream detector contract is `physical_streams_v2_nondec_ts`.** A vehicle stream is a
maximal lane run with `0 <= dt <= 100 ms` (never a backward step) that also satisfies a clock contract
(elapsed `>= 2000 ms`, forward-step ratio `>= 0.30`, zero-step ratio `<= 0.90`) and a dense geometry
contract (quaternion norm valid on `>= 80 %` of records, every position finite and in range, XY
movement span `> 20` units). `dt >= 5` is gone; `dt >= 0` alone is not enough.

Every threshold is derived from the real 2026 regression corpus and is keyed on structure, not on a file
name, a SHA, an offset, a residue or a cadence band:

| threshold | value | corpus evidence |
| --- | --- | --- |
| `STEP_MAX_MS` | 100 | unchanged v1 bound; largest real step observed ~83 ms |
| `MIN_ELAPSED_MS` | 2000 | smallest real accepted stream/fragment = 3623 ms |
| `MIN_POSITIVE_RATIO` | 0.30 | smallest real forward-step ratio = 0.729 |
| `MAX_ZERO_RATIO` | 0.90 | largest real zero-step ratio = 0.271 |
| `MIN_Q_VALID` | 0.80 | unchanged v1 threshold, now applied to every record |
| `MIN_MOVEMENT_SPAN` | 20.0 | smallest real span = 34.7; parked slots measure `0 .. 12.0` |

The **role** stays a sampling/source role. `local_high_frequency` is the highest-cadence shadow and the
rest are `network_low_frequency` in deterministic order. A networked trajectory that looks perfectly
smooth is still `network_low_frequency`; visual quality is never a classifier.

**2. Physical and logical counts are separate published facts.** Physical streams are lane runs; logical
shadows are time/cadence/spatially contiguous groups of them. Nothing may claim N cars from the physical
count alone.

**3. Native semantics are published per owner.** Native Drift/effect action objects are claimed per
shadow by `count_offset` (unchanged). The replay-global action event table is published **only** on the
local authoritative shadow; every other shadow publishes `native_action_event_available = false`,
`native_action_event_ownership = unavailable_non_local_shadow`, a null count, an empty histogram and an
empty timeline. The decoder and the semantic resolution are untouched: this changes attribution only.

**4. The caches bind the detector.** `PhysicalTelemetryCache` becomes
`qpf_v2_nondec_ts_2026schema1_fastpipe1` and its descriptor must carry `detector_contract =
physical_streams_v2_nondec_ts`. A descriptor written by an older detector carries no such field, so it
fails closed and is rebuilt on the next run. `physical_detector` and `raw_cache` are part of
`telemetry_semantic_signature`, and `$script:TelemetrySchemaVersion` moves `18 -> 19` for the new
per-stream ownership field.

## Consequences

- A real networked opponent is recovered as **one** physical stream instead of 2–4 fragments; fragment
  counts collapse (`城市网吧` 20 -> 3 physical streams, `320冒险岛` 16 -> 13).
- A single-player replay still yields exactly one stream. Verified on the whole 34-replay corpus: 24
  files report `1 / 1` before and `1 / 1` after.
- One false logical shadow disappears (`320冒险岛` 8 -> 7), and it is provably an inactive parked slot,
  measured above.
- The grouping heuristic that used to stitch fragments back together is no longer load-bearing for
  coverage: it now only joins a stream that the lane genuinely splits (a real block boundary), and
  `320冒险岛`'s six real network cars still resolve to six shadows.
- A network shadow is honest about what it does not know: it carries trajectory/time/lap/speed and its
  own raw Drift/effect evidence, and no game-facing local action count.
- No measurable detector cost: cold detector time on the pinned replays measures 68–180 ms after vs
  69–177 ms before (the cheap inline clock gate discards frozen lanes before the dense geometry pass).
- Residual unknown: a legitimate vehicle stream shorter than 2 s, or one that moves less than 20 units
  over its whole life, would be rejected by the clock/geometry contract. No such stream is present in
  the observed corpus; the threshold is documented rather than lowered speculatively.
