# ADR 0014 — Resource-declared map identity (`LapDistanceFile.luc`)

Status: accepted
Date: 2026-10-02
Related: `0001` (native-first cutover), `0007` (daily-use analyzer), `0008` (replay readiness cold
contract), `0011` (shared spatial comparison)

## Context

GameMapID `439 一梦青花` could not be resolved to an authoritative ResourceMapID even though the
replay itself was healthy (physical telemetry, native Drift, native action events and episodes were
all ready). The only evidence was the observed `game_map_id = resource_map_id + 100` relation, which
lands on `Map339` — a folder whose scene descriptor claims the same name as `Map338`
(`绝色江西`). Production therefore reported `named_unverified` / `resource_map_id = null` /
`course_key = ""`, which removed the official map, the spatial section layer and same-map A/B for
that map. Two further rows (`112 老街管道`, `325 里约奥运会`) were in the same state, and the
`老街管道` row had been documented as "no authoritative resource row exists at all".

The investigation that produced this record established, with official resources only:

1. **`Map338` and `Map339` are two different courses**, not a copy: `map.nif` 221 139 vs 171 047
   bytes, `sc.nif` 34 837 644 vs 30 644 711, `checkpoint.luc` 283 712 vs 117 555, `pick.nif`
   902 228 vs 672 935, 710 vs 1112 VFS nodes, and **disjoint art vocabularies** — `Map338` ships
   `jiangxi01` (308 files) / `JX01` (117) / `JXTree` (15), `Map339` ships `Qinghuaci` (830).
2. **No official name anywhere is `一梦青花` except the room selection table.** The full descriptor
   sweep (`descriptor_versions.csv`, 2419 descriptor versions, 467 map ids) contains no name with
   `青花`; `map_desc.map_name` is `绝色江西` for *both* folders, and in `data21.vfs` the two
   `map_desc.luc` files are byte-identical. The descriptor name is therefore a **stale, copied
   label**, not a maintained identity.
3. **`Map\Common Map\MapNN\LapDistanceFile.luc` declares the map's own identity.** Its structured
   fields are `lapDistance`, `lapLength`, `mapId`, `mapName`. Measured values:
   `Map338 → mapId 438 / mapName 绝色江西`, `Map339 → mapId 439 / mapName 一梦青花`,
   `Map12 → 112 / 老街管道`, `Map58 → 158 / 玫瑰之恋`, `Map225 → 325 / 里约奥运会`,
   `Map226 → 326 / 鹊桥情缘`. `mapId` is the **game-side MapID namespace** — the same one the room
   selection table `uires\mapsel\maps.luc` stores as `mapid` — and the folder number is *not*
   `mapId - 100` in general (`Map340 → 414`, `Map354 → 167`).
4. **The declaration is versioned and consistent.** 543 records over 328 folders; a folder's
   `mapId` is identical in every archive that declares it (0 conflicting folders). Five folders were
   renamed in place and declare two names across archives (`Map339`: `青花瓷` in `data13.vfs`,
   `一梦青花` from `data14.vfs` on). For all five, the newest archive's name is the one the live room
   table uses for that folder's declared game MapID.
5. **Two game MapIDs are declared by two folders each** (`414 → {314, 340}`, `167 → {67, 354}`).
   That is a genuine conflict in the official data and cannot be resolved by any amount of naming or
   geometry evidence.
6. **The `+100` relation is an observation, not a law.** After the change every one of the 351
   authoritative bindings satisfies `game = resource + 100`, but the resource declarations contain
   counter-examples (`Map340 → 414`, delta 74; `Map354 → 167`, delta −187) precisely among the rows
   whose old, name-join binding was the wrong course.

## Decision

### 1. The catalog consumes the resource declaration

`QQMapSpeedMapCatalog.Core.cs` gains `ParseLapDistanceDescriptors` (plus a typed field extractor that
reads numeric constants, for both the Lua 5.0 and Lua 5.4 descriptor dialects). Every catalog entry
carries:

- `declared_game_map_id` — the declared `mapId`, or `null` when absent / out of range / not unanimous;
- `declared_names` — every declared `mapName` across archives;
- `declared_identity_status` — `unanimous` | `conflicting` | `absent`;
- `declared_name_status` — `usable` | `placeholder_only` | `absent`;
- `name_source` — `lap_distance` | `map_desc`;
- `descriptor_names` / `descriptor_primary_name` / `descriptor_name_status` — the old descriptor
  evidence, retained as reference data.

Reading cost is negligible: 543 tiny files, **0.10 s** in the real build (the whole build is ~6.8 s).

### 2. Identity names come from the maintained declaration

`all_names` is the entry's **identity name set**: the usable declared names when the resource declares
any, otherwise the descriptor names as before. `primary_name` is the declared name of the newest
archive that declares one (`Get-PreferredDeclaredMapName`, ranked by the `data<N>.vfs` suffix so
`data9 < data10` numerically and the bare base archive ranks lowest). A declaration consisting only of
placeholder characters (the client ships one folder whose `mapName` is literally `???`) is not usable,
and that folder keeps its descriptor name.

### 3. The binding authority order

`GRB-BuildBindingsFromData` resolves a game row in this order, and only the first two are structural:

1. verified anchor (explicit cross-namespace record);
2. **resource-declared game MapID** — exactly one folder declares this game MapID →
   `verified_cross_namespace`, `binding_source = resource_declared_map_id`; two or more folders →
   `ambiguous_declared_map_id`, non-authoritative, fail closed;
3. unique exact identity-name join;
4. `game = resource + 100` → `offset_supported_candidate`, never authoritative.

### 4. The open-question set is closed, and stays fail-closed

`map_confirmation_required.json` keeps its contract but its `entries` (the open set) is empty; the
three closed rows and why are recorded under `closed_entries`. A future unresolved row must still be
added there or it is a silent gap. Nothing in this ADR relaxes the near-name, prefix, `+100` or
geometry prohibitions.

## Consequences

`MapCatalog` schema 5 → 6; `map_confirmation_required` schema 1 → 2; `map_coverage_gate_v1` schema
1 → 2. Measured on the real install (before → after):

| quantity | before | after |
| --- | --- | --- |
| catalog `exact_named` maps | 457 | 463 |
| catalog unnamed/ambiguous ids | 10 | 4 |
| catalog duplicate exact names | 64 | 36 |
| catalog alias collisions | 65 | 37 |
| verified Game↔Resource bindings | 231 | **351** (314 declared + 4 anchor + 33 name) |
| offset-only candidates | 147 | 57 |
| ambiguous rows | 47 | 17 (2 declared conflicts) |
| unresolved/special rows | 9 | 9 |
| `+100` exceptions among verified rows | 2 | 0 |

Previously open rows now authoritative: `439 一梦青花 → Map339`, `438 绝色江西 → Map338`,
`112 老街管道 → Map12`, `158 玫瑰之恋 → Map58`, `325 里约奥运会 → Map225`, `326 鹊桥情缘 → Map226`.

Two rows changed course, both because their old binding came from a stale descriptor name and the
resource declares a different one:

- `270 51区`: `Map65 → Map170`. `Map65` declares `165 穿梭之城` (and the room table binds 165 to
  穿梭之城), while `Map170` declares `270 51区`. The old binding came from `Map65`'s stale
  descriptor name `51区`.
- `316 猴园春色`: `Map316 → Map216`. `Map316` declares `416 梦回古蜀`; `Map216` declares
  `316 猴园春色`.

**No row that was authoritative before lost its binding** (`0` regressions), and no currently
verified row changed to an unresolved/ambiguous state.

Real acceptance, two replays of the same map (`5C03C9CDF03A1C4E`, `500BF26A9575A71C`):

- both resolve `Game 439 → Map339`, `map_identity.status = resolved`, `course_key = resource:339`,
  `authoritative = true`, `confidence = verified`;
- `official_map = ready` (Map339 `metadata.json` + `official_map.svg`) and `spatial_driving = ready`;
- same-map A/B is `ready` / `comparable_same_resource_map` / `reconciled`:
  `total_delta_s = +2.531` (95.142 s vs 92.611 s), `matched 2.5313 + unmatched 0 + non-comparison 0
  + residual −0.0003`, 49/49 comparison windows matched, combined coverage 1.0, and swapping subject
  and baseline negates the total exactly (`+2.531` / `−2.531`, sum `0`).

## Regression

- `Tests/Smoke-MapDeclaredIdentity.ps1` (Fast, new): declared-MapID authority, stale-descriptor-name
  rejection, declared-conflict fail-closed, exact-name fallback for entries without a declaration,
  the `+100` row staying a candidate, declared-name validity and archive-version preference, the build
  index bucketing, and — when a rebuilt catalog is present — live structural consistency (every
  uniquely declared game MapID is bound to its declaring folder, every conflict is
  `ambiguous_declared_map_id`, and no stale descriptor name is an identity name).
- `Tests/Smoke-MapCoverage.ps1` (Real, extended): the Game439 case, Game438 unchanged, a
  23-row "must not regress" pin list, the declared-conflict fail-closed rule, the offset class staying
  non-authoritative, no unknown authoritative source, and the corpus carrying the 一梦青花 pair on one
  authoritative ResourceMapID.
- `Tests/Smoke-GameResourceBinding.ps1`, `Smoke-MapResolutionTiers.ps1`,
  `Smoke-UserConfirmedBinding.ps1`, `Smoke-MapIdentityContract.ps1`,
  `Smoke-MapCatalogBuildCoverage.ps1` are unchanged and still pass (the declared channel is additive
  and every consumer treats a missing `declared_game_map_id` as "no declaration").
