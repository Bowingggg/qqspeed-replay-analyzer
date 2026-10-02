# ADR 0003 — Native Action Event Table as a non-authoritative native evidence source

Status: accepted
Date: 2026-10-01
Update 2026-10-01: the decoder contract (structural locator, fail-closed validation, verbatim codes,
raw evidence) stands unchanged, and it now also supports decoding from a container window
(`-BufferOffset` / `-FileLength`, absolute offsets, window failures fail closed). The
**non-authoritative** decision is superseded by `0005`: the action event table is now the production
authority for air boost / landing boost / CW / WCW / CWW, and the timing combo detector is a
diagnostic/disagreement layer.

## Decision

Decode the replay-native **Action Event Table** (previously read by no production code) as a
native *evidence* source, and keep it out of the production authority chain.

1. **Structural locator, not offsets and not a code whitelist.**
   The table layout is `u32 count` followed by `count * { u32 time_ms; u32 action_code; u32 reserved }`.
   It is located from container structure: the table ends exactly where the fixed 374-byte SAV
   trailer begins, so `table_end_exclusive = file_length - 374`, and the count is recovered as the
   **unique self-consistent fixed point** `u32(table_end_exclusive - 4 - 12*count) == count`.
   No per-replay offset is hardcoded, and validity is never gated on a set of known action codes.
2. **Fail closed.** Unable to resolve the count, more than one self-consistent count, a table that
   does not reach the trailer, a non-zero `reserved` field, non-monotonic or out-of-range timestamps
   all yield `status = unavailable` with a specific reason. Nothing is guessed.
3. **Raw evidence preserved.** Each event keeps `record_index`, `record_offset`, `time_ms`,
   `action_code` and `reserved`. Unknown action codes are stored verbatim and never renamed.
4. **Candidate semantics stay non-authoritative.** `code24` = CW/WCW/CWW common marker,
   `code19` = WCW, `code25` adjacent to a `code24` (500 ms, either order) = CW, `code8` = air boost,
   `code9` = landing boost is a research candidate layer. It is not wired into analysis, the
   frontend, or the production CW/WCW/CWW detector, which remains unchanged and authoritative.

## Reasons

- **Grammar-only scanning is provably unsafe.** Scanning the tail for the 12-byte record grammar
  with a code whitelist found exactly one candidate in four replays, none in six, and **fifteen**
  in one. It cannot be made fail-closed.
- **The action codes are not a closed set.** Across 12 archived replays the observed codes are
  `2, 8, 9, 13, 18, 19, 20, 21, 22, 23, 24, 25, 40, 41, 43, 44, 45`. A whitelist would both miss
  real tables (six replays decoded as "no table") and violate the rule that unknown codes are kept.
- **The trailer anchor is strong and testable.** It resolved a valid, self-consistent, unique table
  in **12/12** archived replays and rejected all fifteen grammar false positives.
- **Authority cutover needs separate review.** The candidate model reproduces both gold replays
  exactly, but a production change must be reviewed against the evidence before it can replace the
  existing detector.

## Consequences

- `Modules/Telemetry/ReplayNativeActionEvents.ps1` is a research/native-evidence module. Nothing in
  the production chain, analysis schema or frontend contract consumes it.
- The gold regression (`Tests/Smoke-ReplayNativeActionEvents.ps1`) belongs to the **Real Regression**
  gate, not the Fast Gate, because it asserts real replay truth. Its two gold replays are pinned by
  SHA256 so the golden numbers cannot be satisfied by a different recording.
- Raw `code25` count is **not** the CW count: `code25` also occurs standalone, so CW requires
  adjacency to a `code24`. The 500 ms tolerance is evidence-derived — the largest paired gap observed
  is 283 ms and the smallest unpaired gap is 850 ms, so the tolerance sits inside the observed gap
  rather than being invented.
- Reproducing the gold values does not make the mapping authoritative; unknown codes and the
  remaining unresolved semantics stay recorded rather than resolved.
