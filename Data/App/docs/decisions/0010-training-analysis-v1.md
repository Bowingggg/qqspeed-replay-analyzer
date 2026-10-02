# ADR 0010 — Training Analysis v1: lap, episode, spatial section, same-map A/B, time loss

Status: **partially superseded by `0011`** (the delta direction, the section-vs-section comparison
architecture and the reconciliation tolerance below were replaced; the capability levels, the
fail-closed comparability gate, the "measurement only" rule and the map-independence split still
hold)
Date: 2026-10-01
Related: `0004` (replay data lifecycle), `0005` (native action production authority),
`0007` (daily-use analyzer / Driving Analysis v2), `0009` (capability independence),
`0011` (Training Analysis v1.1 — one delta contract, shared spatial comparison)

## Context

Current-2026 Replay Closure v1 made the replay pipeline trustworthy: the product could say *what a
replay contains* — map identity, physical telemetry, native Drift / actions / effects, official map
geometry, spatial sections. It could not answer the question a driver actually asks:

> "Why was this lap, or this corner, slower than another lap or another recording of the same map?"

The existing derived layers answered a different question. `native_driving_sections_v1` was a
geometry topology with read-only native annotations; `native_driving_episodes_v1` described each
logical Drift action but had no cross-lap or cross-replay comparison; the only A/B existed as a
frontend DP over section anchors with no production contract and no accounting. A user could see
`L1 44.100 s` and `L2 36.784 s` and nothing that connects the difference to anything measured.

Three concrete gaps:

1. **No time attribution.** A lap-time difference was never decomposed into sections, so "0.4 s
   slower in this corner" could not be stated at all.
2. **No same-map contract.** The frontend could pair sections, but there was no production
   comparison contract, no comparability gate and no reconciliation, so a cross-map pairing was a
   presentation accident rather than a refused operation.
3. **No closure.** Nothing checked that a decomposition adds up. A report claiming "2.0 s slower"
   while listing sections that sum to 8.0 s would have looked perfectly confident.

## Decision

### 1. Three capability levels that degrade independently

| level | capability | needs |
| --- | --- | --- |
| 1 | Lap analysis | production telemetry only; **map-independent** |
| 2 | Native driving episode v2 | the replay-native Drift table; **map-independent** |
| 3 | Spatial section / same-map A/B | an **authoritative** official map identity; A/B additionally needs two replays with the **same** `ResourceMapID` |

`native_training_analysis_v1` (`Modules/Native/NativeTrainingAnalysis.ps1`) publishes
`status = ready` when level 3 is available, `ready_without_spatial_sections` when levels 1–2 are
available, and `unavailable` otherwise. A replay whose action event table could not be decoded keeps
its Drift and speed measurements and publishes the action fields as `null` + status: availability
never propagates across capabilities (ADR `0009`).

### 2. Section correspondence is a hard gate, not a nearest-neighbour match

`NTA-AdmissibleAnchors` admits a section pair only when **all** of these hold:

- the two **measured span midpoints** in official world XY are within `MaxAnchorDistanceM` (25 m);
- the observed motion direction is compatible (`left`/`right` must match; `neutral`/`mixed` are
  wildcards because a short section can carry no net direction);
- the observed turn magnitudes differ by at most `MaxHeadingDeltaDeg` (45°) — a hairpin must not be
  anchored onto a gentle kink.

`NTA-SectionAlignmentCore` then solves a monotonic, gap-tolerant correspondence with a
**lexicographic** objective: maximise the number of anchored pairs, then minimise the total
normalised correspondence cost. A flat gap penalty was rejected because the optimum would then
depend on the arbitrary ratio between a skip and a match — which is exactly how forced pairing
creeps back in. An anchor with no admissible counterpart stays **unmatched**.

The midpoint is deliberately chosen over the curvature-peak position: a peak is an extremum whose
location moves with the exact driven trajectory, while the midpoint of the measured span is stable
across laps of one course. This is a measuring point on the driven route and never a reference-line
progress value.

### 3. Delta reconciliation is published, not assumed

Every comparison publishes an explicit partition of the two laps:

```
total_delta                      = lap(B) - lap(A)
matched_section_delta_sum        = sum over anchored pairs of (B window - A window)
unmatched_section_span_delta_sum = anchored_window_delta - matched_section_delta_sum
non_section_delta                = (course outside ANY section), measured per lap
residual                         = total_delta - anchored_window_delta - non_section_delta
```

The residual is **not** a bookkeeping fudge: it is exactly the difference between the two laps'
non-section time as seen through the section boundaries. Section boundaries are quantised to
telemetry frames (≈16.7 ms) and the derived detector places them slightly differently in each lap,
so a residual of a fraction of a second is expected and is published rather than absorbed. A
comparison whose residual exceeds `ResidualToleranceS` (default 0.35 s) is reported
`degraded_residual_exceeds_tolerance`; a comparison whose anchored coverage is below `MinCoverage`
(0.34) is `degraded_low_anchor_coverage`; a comparison with no anchored section at all is
`comparison_unavailable_no_anchored_section` and publishes **every sum as `null`** rather than a
decomposition it cannot support.

Measured reality: an intra-replay lap comparison reconciles (`total −3.373 s, residual −0.246 s`,
coverage 0.82), while two independent recordings of one map do **not** — three real same-map cases
measured residuals of −2.0 to −2.5 s, because two separate recordings section their own course and
genuinely spend different time outside the anchored window. They are published `degraded`, which is
the honest verdict, and the residual is what the user judges.

### 4. Same-map A/B is fail-closed

`NTA-ComparisonGate` allows a comparison only when both sides carry an authoritative and **equal**
official `ResourceMapID`. A different id, an unresolved id or a non-authoritative id produces
`comparison_unavailable` with `breakdown = null` and no loss sections. This is a permanent
regression pinned by both a Fast Gate synthetic (`Smoke-TrainingAnalysis.ps1`) and a Real Regression
(`Smoke-TrainingAnalysisReal.ps1`).

### 5. Measurement only

No score, no grade, no coaching is produced anywhere. Every derived statement is labelled
`derived_observation`, states a measured time difference beside the co-occurring measured
differences, and carries `causation = "not asserted"`. The wording names a **baseline** explicitly:
only the baseline may be called "faster"; the subject is described as slower or faster *than* that
baseline, and no side is ever simply called "slow".

## Consequences

- New modules: `Modules/Native/NativeTrainingSections.ps1` (correspondence kernel, section contract,
  comparability gate), `Modules/Native/NativeTrainingTimeLoss.ps1` (exact partition, delta facts,
  derived observations), `Modules/Native/NativeTrainingAnalysis.ps1` (lap records, intra-replay and
  same-map comparison, the artifact).
- `native_driving_episodes_v1` per-lap metrics gained `lap_start_s`, `lap_end_s`, `max_speed_mps`,
  `median_speed_mps`, `min_speed_mps`, `moving_min_speed_mps`, `median_drift_duration_s`,
  `raw_drift_interval_count`, `drift_available` and `action_event_available`. The action counts now
  publish `null` rather than `0` when the game-facing gate withholds them, which is the same
  "`unavailable` is not `0`" rule the rest of the product follows.
- Analysis schema 24 → 25 (`training_analysis`, `training_status`), plus the
  `native_training_analysis` / `native_training_section` / `native_training_time_loss` /
  `native_training_artifact` contract versions.
- `Write-JsonUtf8` now defaults to `-Depth 24`: the published analysis nests per-lap records inside
  episode aggregates inside native sub-objects, and a too-shallow depth silently serialised a nested
  object as its `ToString()` text instead of failing. `Data\Diagnostics\Dev\` is again the scratch
  root, and `Data\Diagnostics` / `Data` needed a Windows ACL repair before any Fast Gate run.
- New gates: `Tests/Smoke-TrainingAnalysis.ps1` (Fast, synthetic contract) and
  `Tests/Smoke-TrainingAnalysisReal.ps1` (Real Regression, pinned gold replays + same-map + refusal).
- Deliverables: `Output/<replay>_training.json` (full lap / section / episode / comparison detail,
  including the observed trajectory) and `Tools/TrainingAnalysis/` (corpus acceptance +
  `TRAINING_ANALYSIS_BASELINE.md` / `TRAINING_ANALYSIS_FINAL.md`).
- Driver-insight scoring, AI coaching and any canonical/reference line remain **out of scope**.
