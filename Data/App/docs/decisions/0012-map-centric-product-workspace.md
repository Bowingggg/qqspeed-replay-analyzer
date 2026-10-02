# ADR 0012 — Map-centric product workspace

Status: accepted for Product UI v1 first pass

## Context

The native/Training pipeline now produces substantially more data than a driver should see at once. The old frontend exposed most of that data as permanent cards, tables and diagnostics. It also built the replay list by enumerating every JSON file in `Output`, so a derived `<replay>_training.json` could appear as a second replay entity.

The product use case is local: the driver usually wants to point at one part of the route and understand what happened there, or compare that part with another lap/replay.

## Decision

1. **Replay entity identity comes from ReplayCatalog.** The frontend may inspect only canonical `*_analysis.json` artifacts for active catalog entries. Training/comparison/diagnostic JSON files can never create replay cards.
2. **The map is the primary navigator.** Hovering the actual driven route selects the nearest derived spatial section temporarily; clicking locks the selection.
3. **The default inspector is local and sparse.** It shows only time, entry/min/exit speed, drift duration/count, native combo facts, boost latency and route distance needed to understand the selected part.
4. **Training loss/gain is navigation, not a report table.** Top loss/gain windows are compact jump targets. The full reconciliation contract remains available in Advanced diagnostics.
5. **Raw evidence is preserved but demoted.** Code-level evidence, raw 2001/2003/unknown counts, full Episode/section tables and development diagnostics stay behind an Advanced surface.
6. **No new authority is created.** Geometry still locates/measures; native tables still define Drift/actions; Training Analysis v1.1 remains the only signed time-loss contract.

## Consequences

- The everyday UI becomes smaller and route-centric.
- Adding a new derived artifact cannot duplicate a replay in the sidebar.
- A/B side-by-side section facts may be shown for orientation, but independently cut section durations are not presented as formal time loss. Formal signed loss/gain remains Training shared-window data.
- Product UI iterations should reuse validated caches; a true-cold reset is not a default requirement for frontend-only changes.
