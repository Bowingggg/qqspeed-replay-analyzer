# ADR 0006 — The replay catalog lock is an OS handle, not a lock file

Status: accepted
Date: 2026-10-01

## Decision

Catalog mutation serialisation is enforced by an exclusive **file handle**, not by the presence of a lock file:

1. **Acquire** = `[IO.File]::Open(lock, FileMode::CreateNew, FileAccess::ReadWrite, FileShare::None)` and the handle is **held for the whole critical section**. The kernel guarantees that only one process holds it.
2. **A leftover lock file is reclaimed only after an exclusive open proves that nobody holds it** (`FileMode::Open` + `FileShare::None` succeeding). "The file exists" never means "the lock is held", and deleting a lock is therefore permitted only to a process that already proved the instance is unheld. Crash recovery is immediate; there is no age/staleness window.
3. **Release closes the handle first and only then best-effort deletes the file.** A leftover file is harmless, so a failed delete can never stall another writer.
4. **JSON publication is a true atomic replace**: `[IO.File]::Replace(tmp, path, [NullString]::Value, $true)` (= ReplaceFile) with the temp file written under a unique per-writer name. The delete-then-move fallback is removed, so the destination path never disappears; the same contract is used by `Write-JsonUtf8` for telemetry/analysis outputs.
5. **Readers fail closed.** A missing catalog while a foreign writer holds the lock is reported as "write in progress" (retried, then refused) instead of an empty document; a read that failed is reported as a read failure, not as an unsupported contract.

## Reasons

- **The previous implementation lost catalog updates.** Its staleness logic deleted the lock *by name* after observing "missing or too old". That is a check-then-act race: between the observation and the delete, the holder could release and the other writer could create a **new** lock, which the contender then deleted. Two writers entered the critical section, shared the same `replay_catalog.json.tmp`, and one update was lost. Measured at diagnosis time: 7 and 3 simultaneous critical sections per 120-iteration round, plus worker failures on the shared temp file.
- **Every heuristic alternative reintroduces a race.** Age-based staleness, token-verified rename reclaiming and ownership-checked deletion all *reduce* the window but still decide from an observation that can be invalidated before the action. The OS handle has no window: exclusion is a kernel property.
- **The unique temp name plus atomic replace remove the second failure mode** (shared temp clobber, and a reader observing a missing destination during the write).
- **Fail-closed reads are required by the project rule** that an unreadable state must never be silently interpreted as an empty state.

## Consequences

- `ReplayCatalogLockStaleMs` and the observation-based stale path are gone; `Enter-ReplayCatalogLock` returns the handle and `Exit-ReplayCatalogLock` takes it.
- `Tests/Smoke-ReplayLifecycle.ps1` carries the regression in the **Fast Gate**: E-a proves mutual exclusion with a marker written inside the critical section (2 rounds x 120 acquisitions), E-b proves that a concurrent upsert and removal both survive through the real mutators. Both must pass on every Fast Gate run.
- The pre-fix implementation fails E-a (7 and 3 overlaps), so the regression genuinely discriminates; a lock-disabled build fails E-b.
- A crashed writer leaves at most a stale lock **file** behind, which the next acquisition reclaims immediately.
