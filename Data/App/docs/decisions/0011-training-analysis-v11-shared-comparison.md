# ADR 0011 — Training Analysis v1.1: one delta contract, shared spatial comparison, reconciled time loss

Status: accepted
Date: 2026-10-01
Related: `0007` (daily-use analyzer / Driving Analysis v2), `0009` (capability independence),
`0010` (Training Analysis v1 — partially superseded by this record)

## Context

Training Analysis v1 shipped a lap / section / same-map-A-B / time-loss layer, and a design review
plus real acceptance found two independent problems that made it unusable for training.

**1. The delta contract had two opposite directions.** The outer lap comparison published
`subject - baseline` (positive = the subject is slower), while `NTA-TimeLossBreakdown` published
`baseline - subject` and the time-loss ranking sorted by `abs(delta)`. The two conventions met on the
real corpus case: the outer lap total said `+3.373 s` for a lap that took 60.174 s against a 56.801 s
baseline, while the decomposition's own terms summed to `-3.373 s`, and the largest published "top
loss" was a section in which the subject was in fact **faster**. That is a production correctness
defect: a user reading the report would have drawn the opposite conclusion.

**2. Two sides sectioned their own course independently.** Each side ran the geometry detector on its
own telemetry and the two section lists were paired afterwards by nearest measured world-XY anchor.
Two recordings (or two laps) place their boundaries differently, so the paired-vs-unpaired partition
did not tile the two laps and the residual carried the difference. Real acceptance measured
**3 reconciled / 21 degraded / 0 unavailable** over 24 intra-replay comparisons, with residuals of
0.7-4.4 s. Widening the matching threshold or the tolerance would have hidden that, not fixed it.

## Decision

### 1. One delta contract, everywhere

```
delta = subject - baseline
  delta > 0  -> the subject is SLOWER / larger / more
  delta < 0  -> the subject is FASTER / smaller / less
```

`+0.420 s` is a time loss; `-0.180 s` is a time gain. The rule covers lap totals, comparison windows,
matched and unmatched windows, non-comparison stretches, the residual, speed, drift duration, boost
latency, route distance, observations, the JSON contract and the interface. `top_loss_sections`
contains only `delta > 0` ranked descending and `top_gain_sections` only `delta < 0` ranked by
magnitude descending; a comparison with no loss publishes an empty loss list, which is a result and
not a failure.

The roles are named explicitly (`subject` / `baseline`, with `subject_replay` / `baseline_replay` on
the same-map contract) instead of a bare `A`/`B`, and exchanging the two arguments negates every
signed metric.

### 2. Shared spatial comparison replaces "each side sections itself, then pair"

`NTA-SharedCorrespondence` (`Modules/Native/NativeTrainingSections.ps1`) builds a correspondence
between the two **real driven trajectories**:

- each lap is resampled into control points at a bounded arc-length step (`MaxPoints`, and never
  finer than `MinStepM`), split at invalid poses and `break_before` rows so a respawn can never be
  bridged;
- a banded, monotone dynamic program over the two control-point sequences maximises the number of
  corresponded pairs and then minimises the total measured spatial separation, inside a hard
  separation gate and a heading-compatibility gate, and inside a progress band;
- the result is monotonic, order preserving, bounded (linear in the control-point count, never a raw
  frame matrix) and **fail-closed**: a control point with no admissible counterpart stays unmatched,
  coverage is never forced, and a progress gap above `MaxGapProgress` splits the correspondence into
  components.

**Time is never part of the cost.** The correspondence answers *which positions of these two driven
routes correspond*; a timestamp in the cost would align a slower replay onto the wrong position.
Times are only measured afterwards, on each side of a window.

A shared progress is then defined on the correspondence, and ONE boundary set is built on it from the
union of both sides' section boundaries. The existing Driving Sections are used as a structural
hint only; the comparison windows themselves are unified on the shared progress, so both sides
measure **the same windows**. A window exists wherever the routes correspond, whether or not either
side drifted there: native actions remain read-only facts of each side, assigned to a window by their
own drift start time, so "one side drifted, the other did not" stays a count difference and never
becomes a forced pairing.

### 3. Reconciliation with a derived tolerance

```
total_delta            = subject_lap_time - baseline_lap_time
matched_delta          = sum over windows whose correspondence is `matched`
unmatched_delta        = sum over windows whose correspondence is ambiguous / insufficient
non_comparison_delta   = (subject time OUTSIDE every window) - (baseline time outside every window)
residual               = total_delta - matched_delta - unmatched_delta - non_comparison_delta
```

The comparable stretches are measured with sub-sample interpolation. A non-comparison stretch - the
part of a lap the two routes do not share - is published as a whole telemetry-row span, because that
is the only resolution at which it can be inspected row by row. The residual is exactly that
quantisation difference, so the tolerance is **derived from measured quantities**:

```
tolerance = (2 * non_comparison_spans + 2) * measured_median_sample_interval
```

Each non-comparison boundary is resolved to the nearest telemetry sample, the identity spans both
sides, and the constant 2 covers the two lap boundaries. Nothing is tuned.

Verdicts: `reconciled` when the residual is inside the tolerance and the shared coverage is at least
`MinCoverage`; `degraded_residual_exceeds_tolerance`; `degraded_low_correspondence_coverage`;
`comparison_unavailable_no_shared_correspondence` (all sums `null`, never `0`).

### 4. The comparison window is the published unit

Every window publishes identity, the subject/baseline start and end on the shared progress plus their
world-XY positions, the subject/baseline/delta time with an explicit `direction` and
`classification`, subject/baseline/delta entry/min/exit/average speed, subject/baseline/delta native
Drift facts (logical drift count, drift active time, CW/WCW/CWW, air, landing, small-boost and nitro
raw counts, boost latency), the route-distance delta, and the correspondence status of the stretch
(`matched` / `ambiguous_*` / `unmatched_*`, pair count and separations).

### 5. What does NOT change

Native Drift / Action Event / speed-effect authority, the geometry-only section detector, the
fail-closed comparability gate, the `unavailable != 0` rule, and the "no score, no grade, no
coaching" limit are untouched. This milestone changes comparison architecture and sign semantics only.

## Consequences

- `native_training_time_loss_v1` publishes `reconciliation` (`matched_delta_s`, `unmatched_delta_s`,
  `non_comparison_delta_s`, `residual_s`, `residual_abs_s`, `residual_ratio`, `tolerance_s`,
  `tolerance_basis`, `status`, `status_reason`), `coverage`, `windows`, `non_comparison_spans`,
  `correspondence` and the separated `top_loss_sections` / `top_gain_sections`.
- `native_training_same_map_comparison_v1` publishes explicit `subject` / `baseline` role blocks and
  `subject_replay` / `baseline_replay`, and every signed metric is `subject - baseline`.
- Observations print the signed delta together with the word for **that same sign**; the sentence
  never contradicts its own number and `causation` is still `not asserted`.
- Frontend wiring is limited to correctness: the section table became the shared-window table, the
  "who is faster" column became an explicit loss/gain classification driven by the sign, and gain
  windows are listed as gains. No UI redesign.
- `Tests/Smoke-TrainingAnalysis.ps1` (Fast) pins the correspondence properties, Case A
  (`60.174` vs `56.801` -> `+3.373 s`, outer == decomposition), Cases B/C (`+1.0` -> slower/loss,
  `-1.0` -> faster/gain), Case D (observation direction), loss/gain separation, the swap invariant
  and the fail-closed refusals. `Tests/Smoke-TrainingAnalysisReal.ps1` (Real) pins the same
  invariants on real replays, including a live swap-invariant measurement.
- Real corpus result: intra-replay reconciliation moved from 3 reconciled / 21 degraded to the
  measured figures in `docs/STATUS.md`, and the same-map A/B residual collapsed, because the two
  sides now measure the same windows.
