# Test-suite alignment

Every suite runs in two parts. **Part 1, CORE:** the fourteen sections
C01 to C14, in order, holding only core assertions. Their ids and labels
come from [`tests/core_spec.tsv`](tests/core_spec.tsv) and are the same
in all ten suites; each model supplies its own SQL. **Part 2, MODEL:**
that model's own sections, M01 onwards, holding every other assertion.

`make core-check` (`tests/check_core.sh`) runs the suites and fails if one
misses a core id, emits one twice, or emits them out of order; all ten
pass. `make verify` reports core, model and gap counts per suite, and
fails if any suite's core total differs. A suite ends with:

```
  RESULT: <passed> passed, <failed> failed, <gaps> known gap(s)
  CORE : <passed>/36 passed
  MODEL: <passed> passed
  GAP  : <gaps>
```

A core GAP line is an expected failure: the model cannot pass that core
assertion today, and C4b closes it later. It counts as emitted for
`make core-check` and does not fail the suite.

The nine question assertions (Q1 to Q9) read their SQL from
`v3_*/tests/answers/Q<n>.sql`, so the C4 answer matrix can reuse it.

This file maps every assertion that existed before the alignment to its
new place. No assertion was dropped or weakened.

## Progress

| Suite | Aligned | Core | Model | Gap | Before |
|---|---|---|---|---|---|
| `v3_inmon-3nf` | run 1 | 36/36 | 58 | 0 | 80 |
| `v3_data-marts` | run 2 | 36/36 | 65 | 0 | 88 |
| `v3_datavault` | run 2 | 36/36 | 283 | 0 | 304 |
| `v3_hook` | run 2 | 36/36 | 93 | 0 | 115 |
| `v3_unified-star-schema` | run 3 | 36/36 | 104 | 0 | 129 |
| `v3_activity-schema` | run 3 | 36/36 | 117 | 0 | 139 |
| `v3_one-big-table` | run 3 | 36/36 | 49 | 0 | 71 |
| `v3_focal-point` | run 4 | 35/36 | 177 | 1 core | 142 + 48 (two suites) |
| `v3_anchor` | run 4 | 36/36 | 97 | 0 | 124 |
| `v3_metrics-mart` | run 4 | 35/36 | 201 | 1 core | 222 |

## How assertions moved

- **Core.** An old assertion that tests a core claim becomes that core
  assertion. Its SQL is kept; only the label changes to the shared one.
- **Merged.** Where an old assertion was narrower than its core assertion,
  the core one keeps the old check and adds to it. The old label is
  listed against the core id with "merged".
- **Evaluated in place, reported in MODEL.** A model check that sat inside
  a D-section is still evaluated at the same moment (the state after that
  delivery), but its result is reported in the MODEL section named after
  it. Part 1 then holds only core lines, and no check moved to a point
  where the warehouse holds different data.
- **The raw archive is the final answer.** Where a model updates history
  away in place (Kimball's restated fact, the metrics mart's current
  state), a core question is answered from the raw archive, and that
  counts as answered. One Big Table answers all of its history from the
  log the same way. A core GAP is kept only for a claim the model cannot
  meet even with the archive.
- **Per-delivery manifest and stage checks** (`[B0] manifest: recorded
  exactly once` and the like) are model assertions, reported together in
  M01.

## v3_inmon-3nf

Before: 80 assertions. After: 94 (36 core, 58 model). The 14 new ones are
all core: C01.1, C02.2, C02.3, C03.1, C03.4, C04.4, C05.4, C06.1, C07.1,
C07.3, C07.4, C08.3, C08.4, C14.1.

| Old label | New place | Note |
|---|---|---|
| baseline: 2 customers, 3 products, 2 orders current | C02.1 | merged: the core assertion also counts the 3 order lines |
| baseline: C001 email v1 | M02 baseline: C001 email v1 | |
| CONFORMED AT INGEST: EDW stores PENDING, archive keeps raw 'P' | M03 (same label) | C02.2 (Q5) separately asks what 'P' reads as |
| 3NF: the relationship is a plain natural-key FK column | M04 (same label) | |
| time-variant: C001 now 2 rows, old one CLOSED (an UPDATE happened) | M05 (same label) | evaluated after D1 |
| INCREMENTAL: C002 NOT deleted (60-day stale) | C03.2 | |
| INCREMENTAL: C002 zero churn | C03.3 | |
| NATURAL-KEY JOIN: v_order sees the CURRENT customer, always | M04 (same label) | evaluated after D1 |
| FULL: SKU-3 closed + deleted-marker row (2 versions) | M05 (same label) | evaluated after D2 |
| FULL: SKU-3 gone from v_product | C04.2 | |
| FULL: SKU-1 price 8.99 via new version | C04.1 | |
| FULL: SKU-2 zero churn | C04.3 | |
| tombstone: C002 deleted-marker current | C05.1 | |
| tombstone: C002 gone from v_customer | C05.2 | |
| tombstone: O-101 placed_by now NULL (current join finds nobody) | C05.3 | |
| RANGE JOIN: as-recorded still answers Bob Jones (the BETWEEN gymnastics) | C05.5 (Q7) | merged: the range join is now `answers/Q7.sql`, which takes O-101's first recorded version instead of a hard-coded timestamp |
| recency: newest email wins (not MAX) | C06.2 | |
| recency: one delivery -> one version | M05 (same label) | evaluated after D4 |
| dup file skipped: EDW unchanged | C07.2 | |
| reconcile: C003 deleted by absence (FULL) | C08.1 | |
| reconcile: C001 unchanged content -> zero churn (still 2) | M05 (same label) | evaluated after D5 |
| reconcile: C002 already deleted -> zero churn (still 2) | M05 (same label) | evaluated after D5 |
| reconcile: v_customer shows only C001 | C08.2 (Q1) | |
| re-asserted current state writes zero EDW rows | C09.1 | |
| archive captured every delivered row | C10.1 | |
| UPDATE on hist_customer aborts | C10.2 | |
| DELETE on hist_order aborts | C10.3 | |
| clean+rebuild: EDW identical | C11.1 | |
| live rule change does NOT touch stored rows (conformed at ingest) | M03 (same label) | evaluated in C12, before the rebuild in a scratch copy |
| seed edit + rebuild re-derives history under the new rule | C12.1 (Q9) | merged and stricter: it read the distinct current status; Q9 lists every version of every order |
| repoint: O-101 versioned, not updated in place (2 rows) | M06 (same label) | evaluated after D6 |
| repoint: current version points at C001 | M06 (same label) | evaluated after D6 |
| repoint: placed_by resolves to Alice Smith | C13.1 (Q8) | merged: Q8 lists every current owner, so a second one would fail it |
| repoint: the old pairing survives as order history | C13.2 | |
| re-asserted repoint writes nothing | M06 (same label) | |
| `[<id>] manifest: recorded exactly once`, for B0, D1, D2, D3, D4, D1 (re-sent), D5, D5R, D6, D6R | M01 (same labels) | 10 assertions |
| `[<id>] manifest: COMPLETE after the loader`, for every delivery except the skipped D1 re-send | M01 (same labels) | 9 assertions |
| `[<id>] stage blank after delivery`, for every delivery | M01 (same labels) | 10 assertions |
| the 16 `reuse:` assertions of "Load control: a file_id names CONTENT" | M07 (same labels) | the block is unchanged apart from `ck` becoming `own`; it is byte-identical across the suites again once all ten are converted |

Unplaced assertions: none.

## v3_data-marts (Kimball)

Before: 88 assertions. After: 101 (36 core, 65 model). The 15 new ones
are all core: C01.1, C02.2, C02.3, C03.4, C04.4, C05.4, C06.1, C07.1,
C07.3, C07.4, C08.3, C08.4, C13.1, C13.2, C14.1.

**C13.2 "O-101's earlier owner is still answerable"** is answered from the
raw archive: the re-point UPDATEs the fact row in place, so the star no
longer holds C002. (Run 2 reported this as a GAP; on review, the archive
is the final answer in every model.)

| Old label | New place | Note |
|---|---|---|
| baseline: 2 customers current | C02.1 | merged: one core count covers customers, products, orders and lines |
| baseline: 3 products current | C02.1 | merged, as above |
| baseline: 2 facts, 3 lines | C02.1 | merged, as above |
| baseline: C001 email v1 | M02 (same label) | |
| baseline: dim_date generated | M02 (same label) | |
| baseline: fact joins the calendar (O-100 -> Sunday) | M02 (same label) | |
| decode dim: raw 'P' lives in archive, mart shows PENDING | M03 (same label) | C02.2 (Q5) separately asks what 'P' reads as |
| SCD2: C001 now has 2 versions | M04 (same label) | evaluated after D1 |
| SCD2: exactly one is current | M04 (same label) | evaluated after D1 |
| SCD2: old version expired at batch ts | M04 (same label) | evaluated after D1 |
| INCREMENTAL: C002 NOT deleted (60-day stale) | C03.2 | |
| INCREMENTAL: C002 no version churn | C03.3 | |
| FROZEN KEY: O-100 fact still points at C001 v1 | M05 (same label) | evaluated after D1 |
| ...while the current dim says newmail | C03.1 | |
| FULL: SKU-3 expired + deleted-marker version (2 rows) | M04 (same label) | evaluated after D2 |
| FULL: SKU-3 current version flagged deleted | M04 (same label) | evaluated after D2 |
| FULL: SKU-3 gone from mart_products | C04.2 | |
| FULL: SKU-3 last-known attrs preserved | M04 (same label) | evaluated after D2 |
| FULL: SKU-1 price 8.99 via new version | C04.1 | |
| FULL: SKU-2 unchanged -> no churn | C04.3 | |
| tombstone: C002 current version is a deleted marker | C05.1 | |
| tombstone: C002 gone from mart_customers | C05.2 | |
| tombstone: last-known attrs carried onto the marker | M04 (same label) | evaluated after D3 |
| POINT-IN-TIME: O-101 still answers 'Bob Jones' at purchase | C05.5 (Q7) | |
| ...and NULL for placed_by_current (matches the sibling demos) | C05.3 | |
| recency: newest email wins (not MAX) | C06.2 | |
| recency: one delivery -> one version | M04 (same label) | evaluated after D4 |
| dup file skipped: star unchanged | C07.2 | |
| reconcile: C003 deleted by absence (FULL) | C08.1 | |
| reconcile: C001 unchanged content -> NO new version (still 2) | M04 (same label) | evaluated after D5 |
| reconcile: C002 already deleted -> no churn (still 2) | M04 (same label) | evaluated after D5 |
| reconcile: mart shows only C001 | C08.2 (Q1) | |
| re-asserted current state writes zero star rows | C09.1 | |
| archive captured every delivered row | C10.1 | |
| UPDATE on hist_customer aborts | C10.2 | |
| DELETE on hist_order aborts | C10.3 | |
| clean+rebuild: star identical, SURROGATE KEYS included | C11.1 | |
| Type 1 change: every fact reads PLACED instantly, no reload | C12.1 (Q9) | merged and stricter: it read the distinct status; Q9 lists every order |
| ...and rebuild resets it: schema seed is the source of truth | M03 (same label) | evaluated in C12 |
| repoint: fact row count unchanged (an UPDATE, not an insert) | M06 (same label) | evaluated after D6 |
| repoint: O-101 now keyed to C001's current version | M06 (same label) | evaluated after D6. C13.1 (Q8) separately asks who owns O-101 now, through `placed_by_current` |
| repoint: prior pairing survives ONLY in the archive | M06 (same label) | C13.2 asks the same question of the archive by name |
| re-asserted repoint writes nothing | M06 (same label) | |
| `[<id>] manifest: ...` and `[<id>] stage blank after delivery`, for every delivery | M01 (same labels) | 29 assertions |
| the 16 `reuse:` assertions | M07 (same labels) | the shared block, now byte-identical to Inmon's |

Unplaced assertions: none.

## v3_datavault

Before: 304 assertions. After: 319 (36 core, 283 model). The 18 new core
assertions are C01.1, C02.1, C02.2, C02.3, C03.4, C04.4, C05.5, C06.1,
C07.1, C07.3, C07.4, C08.2, C08.4, C09.1, C11.1, C12.1, C13.2 and
C14.1. Three new model assertions come with C09: the D5R re-send's
manifest and stage checks (M01).

**Ordering changes, no change in meaning.**
- **C09 Idempotence.** The core check re-sends D5's content as D5R
  before the archive and rebuild sections, as in the other suites. The
  vault's own "new id, loaders run, nothing written" check on D6's
  content (D6R) stays, in M04.
- **C11 Rebuild.** One core assertion that every vault table, the
  reference table and the business-vault views come back row for row. The
  per-table detail behind it (`rebuild_check`) is unchanged, in M08. The
  first rebuild now also replays D5R, so the label "six deliveries" undercounts
  by one; it is kept so the mapping stays exact.
- **C12 Rule change.** It inserts the new reference row (`P` -> `PLACED`)
  into a copy of the vault, not the main vault. A reference row in the main
  vault would not survive the two rebuilds still to come. The vault's own
  no-reload scenario (`AWAITING SHIPMENT`) still runs in the main vault,
  after the last rebuild, in M11.
- **D7, the soft-rule scenario and the reserved-value refusal** run live in
  PART 2 (M10 to M12), after the core, in the same order as before.

| Old label | New place | Note |
|---|---|---|
| baseline: 2 customer keys / 3 product keys / 2 order keys | M03 (same labels) | hub counts; C02.1 counts the current dimension and fact rows |
| baseline: C001 email v1 | M02 (same label) | |
| baseline: 2 current order->customer pairings | M04 (same label) | |
| RAW: vault stores source code 'P', mart translates | M11 (same label) | evaluated after D0 |
| INCREMENTAL: C001 email updated | C03.1 | |
| INCREMENTAL: C002 NOT deleted (60-day stale) | C03.2 | |
| INCREMENTAL: C002 email unchanged | M02 (same label) | |
| INCREMENTAL: C002 no sat churn (1 row) | C03.3 | |
| grain: C001 change = ONE whole-row sat version (2 total) | M03 (same label) | |
| FULL: SKU-3 deleted on absence (sts='D') | M03 (same label) | C04.2 asserts it is gone from `dim_product` |
| FULL: SKU-3 hub key remains (insert-only) | M03 (same label) | |
| FULL: SKU-3 history remains in its satellite | M03 (same label) | |
| FULL: SKU-3 gone from dim_product | C04.2 | |
| FULL: SKU-1 price changed 8.99 | C04.1 | |
| FULL: SKU-2 unchanged -> hashdiff wrote nothing (1 row) | C04.3 | |
| tombstone: C002 sts='D' | C05.1 | |
| tombstone: C002 gone from dim_customer | C05.2 | |
| tombstone: O-101 placed_by now NULL | C05.3 | |
| tombstone: C002 attribute history intact | C05.4 | merged and stricter: now checks the email as well as the name |
| CPIT: deleted C002 keeps its row, its sts pointer names the 'D' row | M06 (same label) | |
| recency: newest email wins (not MAX) | C06.2 | |
| recency: one delivery -> one sat row | M03 (same label) | |
| dup file skipped: vault unchanged | C07.2 | |
| reconcile: C003 deleted by absence (FULL) | C08.1 | |
| reconcile: C001 survives | M02 (same label) | |
| reconcile: C002 stays deleted | C08.3 (Q2) | merged and stricter: Q2 requires C002 and C003, and nobody else |
| reconcile: C001 unchanged content -> NO new sat row (still 2) | M03 (same label) | |
| C002 presence timeline is exactly I -> D (2 assertions) | M03 (same label) | |
| every `cpit_check` assertion (after D5, after D6, after D7) | M06, M06, M10 (same labels) | |
| every `reserved_check` assertion (init, after the full replay, after D7, after the refused delivery) | M05, M05, M10, M12 (same labels) | |
| UPDATE / DELETE on each raw-vault table aborts; only the bv_ query-assist tables can be rewritten; the two loader-style reserved-key inserts abort | M07 (same labels) | evaluated in C10 |
| archive captured every delivered row | C10.1 | |
| UPDATE on hist_customer / hist_product / hist_order / hist_order_line aborts | C10.2 | merged: one core assertion covers all four tables |
| DELETE on hist_customer / hist_product / hist_order / hist_order_line aborts | C10.3 | merged: one core assertion covers all four tables |
| every `rebuild_check` assertion ("six deliveries", "after D6R", "after D7") | M08, M08, M10 (same labels) | C11.1 summarises the first |
| replay: zero new vault rows | M09 (same label) | the same-id re-send of the whole sequence |
| repoint: O-101 current customer is C001 | M04 (same label) | |
| repoint: exactly ONE current pairing for O-101 | M04 (same label) | |
| repoint: old pairing end-dated by LEAD, not updated | M04 (same label) | C13.2 separately asks for the earlier owner |
| repoint: link table keeps BOTH pairs (insert-only history) | M04 (same label) | |
| repoint: placed_by resolves to Alice Smith | C13.1 (Q8) | merged: Q8 lists every current pairing, so a second one would fail it |
| repoint: unchanged order attrs -> no new sat row | M04 (same label) | |
| repoint: CPIT effectivity pointer is C001, opened by D6 | M06 (same label) | |
| repoint: bridge carries O-101's line under C001 only | M06 (same label) | |
| re-asserted current state writes zero vault rows | M04 (same label) | D6R |
| the seven `null customer_ref:` / `no satellite row:` assertions and the eleven `no reserved key in ...` assertions | M10 (same labels) | |
| raw 'P' still in the vault; mart derives PENDING from it today; the decode is a view; the mart holds no decode of its own; the five `new reference row:` assertions | M11 (same labels) | |
| customer_id '0' is refused before any loader runs | M12 (same label) | |
| `[<id>] manifest: ...` and `[<id>] stage blank after delivery`, for every delivery | M01 (B0 to D6R) and inline in M10 (D7) | 41 before, 44 now with D5R |
| the 16 `reuse:` assertions | M13 (same labels) | the shared block, now byte-identical to Inmon's |

Unplaced assertions: none.

## v3_hook

Before: 115 assertions. After: 129 (36 core, 93 model). The 14 new ones
are all core: C01.1, C02.2, C02.3, C03.1, C03.4, C04.4, C05.4, C06.1,
C07.1, C07.3, C07.4, C08.3, C08.4, C14.1.

| Old label | New place | Note |
|---|---|---|
| registry: every frame column named in hook_column exists on its frame | M02 (same label) | evaluated after init |
| registry: every hk_* column on every frame is registered | M02 (same label) | evaluated after init |
| registry: v_hook_occurrence covers every registered hook column | M02 (same label) | evaluated after init |
| no hub, link or satellite tables -- data lives only in frames | M02 (same label) | evaluated after init |
| baseline: 2 customers, 3 products, 2 orders current | C02.1 | merged: the core assertion also counts the 3 order lines |
| baseline: C001 email v1 | M03 (same label) | |
| HOOK = key set + business key | M02 (same label) | |
| frame keeps the source columns verbatim (raw customer_id beside the hook) | M02 (same label) | |
| relationship = a second hook on the order row (no link table) | M02 (same label) | |
| order line frame grain is the hook pair (3 pairs) | M02 (same label) | |
| SOFT RULE ON READ: frame stores raw 'P', v_order decodes PENDING | M07 (same label) | |
| lineage: every frame row names its delivery | M04 (same label) | |
| delta: C001 now 2 frame rows, the new one an UPDATE | M04 (same label) | |
| insert-only: C001's first row still holds the old email | M04 (same label) | |
| INCREMENTAL: C002 NOT deleted (60-day stale) | C03.2 | |
| INCREMENTAL: C002 zero churn | C03.3 | |
| HOOK JOIN: v_order resolves placed_by through the shared CRM.CUST key set | M02 (same label) | |
| FULL: SKU-3 gets a DELETE row, basis FULL_ABSENCE | M04 (same label) | |
| FULL: SKU-3 gone from v_product | C04.2 | |
| FULL: the DELETE row carries the business key, no attributes | M04 (same label) | |
| FULL: SKU-1 price 8.99 via a new frame row | C04.1 | |
| FULL: SKU-2 unchanged -> NOCHANGE, zero churn | C04.3 | |
| FULL product feed leaves the other frames untouched | M04 (same label) | |
| tombstone: C002 latest row is DELETE/TOMBSTONE | C05.1 | |
| tombstone: C002 gone from v_customer (no ghost row) | C05.2 | |
| tombstone: O-101 placed_by now NULL (current join finds nobody) | C05.3 | |
| AS-OF: v_order_as_recorded still answers Bob Jones | C05.5 (Q7) | merged: Q7 takes O-101's first recorded row instead of a hard-coded timestamp |
| tombstone: C002 has exactly one DELETE row | M04 (same label) | |
| recency: newest email wins (not MAX) | C06.2 | |
| recency: one delivery -> one frame row | M04 (same label) | |
| dup file skipped: frames unchanged | C07.2 | |
| reconcile: C003 deleted by absence (FULL) | C08.1 | |
| reconcile: C001 unchanged content -> zero churn (still 2) | M04 (same label) | |
| reconcile: C002 already deleted -> zero churn (still 2) | M04 (same label) | |
| reconcile: D5 wrote exactly one frame row (the C003 delete) | M04 (same label) | |
| reconcile: v_customer shows only C001 | C08.2 (Q1) | |
| re-asserted current state writes zero frame rows | C09.1 | |
| CUSTOMER concept: 3 members ever seen (deleted ones included) | M05 (same label) | evaluated after D5R, as before |
| C001 is hooked from two frames (CRM customer + OMS order) | M05 (same label) | |
| SKU-3 never ordered: hooked from the product frame only | M05 (same label) | |
| integration: every order's customer hook lands on a customer frame row | M05 (same label) | |
| UPDATE on a frame aborts | M06 (same label) | |
| DELETE on a frame aborts | M06 (same label) | |
| archive captured every delivered row | C10.1 | |
| frames are delta-compressed: fewer rows than the archive holds | M06 (same label) | |
| UPDATE on hist_customer aborts | C10.2 | |
| DELETE on hist_order aborts | C10.3 | |
| clean+rebuild: frames identical (load_ts and record_source included) | C11.1 | |
| live ref change is visible immediately in v_order | M07 (same label) | evaluated in C12 |
| ...and in history: as-recorded rows re-read under the new rule | C12.1 (Q9) | merged and stricter: it read the distinct status; Q9 lists every order frame row |
| ...while the frames still hold the raw code | M07 (same label) | evaluated in C12 |
| repoint: O-101 has 2 frame rows, the new one an UPDATE | M08 (same label) | |
| repoint: latest hook points at CRM.CUST\|C001 | M08 (same label) | |
| repoint: placed_by resolves to Alice Smith | C13.1 (Q8) | merged: Q8 lists every current owner |
| repoint: the old hook survives as history | C13.2 | |
| repoint: exactly one current customer per order | M08 (same label) | |
| repoint: as-recorded reads each row against its own moment | M08 (same label) | |
| re-asserted repoint writes nothing | M08 (same label) | |
| a customer hook from an unregistered/wrong key set is flagged | M09 (same label) | |
| ...and does NOT integrate: ERP.CUST\|C001 is not CRM.CUST\|C001 | M09 (same label) | |
| `[<id>] manifest: ...`, `[<id>] stage blank after delivery` and `[<id>] hook integrity: ...`, for every delivery | M01 (same labels) | 39 assertions |
| the 16 `reuse:` assertions | M10 (same labels) | the shared block, now byte-identical to Inmon's |

Unplaced assertions: none.

## v3_unified-star-schema

Before: 129 assertions. After: 140 (36 core, 104 model). The 13 new ones
are all core: C01.1, C02.2, C02.3, C03.4, C04.4, C05.4, C06.1, C07.1,
C07.3, C07.4, C08.3, C08.4, C14.1.

| Old label | New place | Note |
|---|---|---|
| each USS table has exactly one _key_ column: its own | M02 (same label) | evaluated after init |
| orders has no customer_ref: the relationship lives on the bridge | M02 (same label) | evaluated after init |
| the bridge carries every table's key | M02 (same label) | evaluated after init |
| baseline: 2 customers, 3 products, 2 orders current | C02.1 | merged: the core assertion also counts the 3 order lines |
| baseline: C001 email v1 | M03 (same label) | |
| bridge: 2+3+2+3 = 10 rows across 4 stages | M02 (same label) | |
| core keeps raw 'P'; the USS table holds PENDING (+ raw code for lineage) | M07 (same label) | |
| TRANSITIVE KEY: an order line carries its order's customer | M02 (same label) | |
| measures sit on their own stage only | M04 (same label) | |
| FAN TRAP: naive join double counts O-100; the bridge does not | M04 (same label) | |
| one query, two grains: C001 has 1 order, 29.49, 2 lines | M04 (same label) | |
| SKU-3 never ordered but still on the star (Product stage) | M04 (same label) | |
| lineage: every core row names its delivery | M05 (same label) | |
| core: C001 now 2 rows, the new one an UPDATE | M05 (same label) | |
| insert-only: C001's first core row still holds the old email | M05 (same label) | |
| USS shows the new email | C03.1 | |
| INCREMENTAL: C002 NOT deleted (60-day stale) | C03.2 | |
| INCREMENTAL: C002 zero churn | C03.3 | |
| v_order resolves placed_by through the bridge | M02 (same label) | |
| FULL: SKU-3 core row DELETE, basis FULL_ABSENCE | M05 (same label) | |
| FULL: SKU-3 gone from product and from the Product stage | C04.2 | |
| FULL: SKU-1 price 8.99 | C04.1 | |
| FULL: SKU-2 unchanged -> NOCHANGE, zero churn | C04.3 | |
| FULL product feed leaves the other core tables untouched | M05 (same label) | |
| tombstone: C002 latest core row is DELETE/TOMBSTONE | C05.1 | |
| tombstone: C002 gone from v_customer (no ghost row) | C05.2 | |
| tombstone: O-101 placed_by now NULL | C05.3 | |
| the bridge keeps O-101's key to C002, so its amount still counts | M04 (same label) | |
| sales by customer: C002's 19.5 survives with no name | M04 (same label) | |
| AS-OF (from the core): as-recorded still answers Bob Jones | C05.5 (Q7) | merged: Q7 takes O-101's first recorded row instead of a hard-coded timestamp |
| tombstone: C002 has exactly one DELETE row | M05 (same label) | |
| recency: newest email wins (not MAX) | C06.2 | |
| recency: one delivery -> one core row | M05 (same label) | |
| NO CHASM TRAP: order-less C003 still appears in sales by customer | M04 (same label) | |
| dup file skipped: core unchanged | C07.2 | merged with the next: C07.2 compares the core and the bridge |
| dup file skipped: bridge unchanged | C07.2 | merged, as above |
| reconcile: C003 deleted by absence (FULL) | C08.1 | |
| reconcile: C001 unchanged content -> zero churn (still 2) | M05 (same label) | |
| reconcile: C002 already deleted -> zero churn (still 2) | M05 (same label) | |
| reconcile: D5 wrote exactly one core row (the C003 delete) | M05 (same label) | |
| reconcile: v_customer shows only C001 | C08.2 (Q1) | |
| reconcile: C003 left the Customer stage | M02 (same label) | |
| re-asserted current state writes zero core rows | C09.1 | merged with the next: C09.1 compares the core and the bridge |
| ...and the refreshed bridge is identical | C09.1 | merged, as above |
| UPDATE on a core table aborts | M06 (same label) | |
| DELETE on a core table aborts | M06 (same label) | |
| archive captured every delivered row | C10.1 | |
| core is delta-compressed: fewer rows than the archive holds | M06 (same label) | |
| UPDATE on hist_customer aborts | C10.2 | |
| DELETE on hist_order aborts | C10.3 | |
| clean+rebuild: core AND bridge identical | C11.1 | |
| live ref change is NOT yet visible (the USS is materialised) | M07 (same label) | evaluated in C12 |
| refresh_uss.sh alone applies it -- no core reload | M07 (same label) | evaluated in C12 |
| ...and the history view reads it on the fly | C12.1 (Q9) | merged and stricter: it read the distinct status; Q9 lists every order core row |
| ...while the core still holds the raw code | M07 (same label) | evaluated in C12 |
| repoint: core O-101 has 2 rows, the new one an UPDATE | M08 (same label) | |
| repoint: Orders stage now keys O-101 to C001 | M08 (same label) | |
| repoint: the order LINE followed its order (transitive key) | M08 (same label) | |
| repoint: placed_by resolves to Alice Smith | C13.1 (Q8) | merged: Q8 lists every current owner |
| repoint: C001 now owns both orders, all 3 lines, 48.99 | M08 (same label) | |
| repoint: C002 has left the star entirely | M08 (same label) | |
| repoint: the old pairing survives in the core | C13.2 | |
| repoint: as-recorded reads each core row against its own moment | M08 (same label) | |
| repoint: still no fan trap | M08 (same label) | |
| re-asserted repoint writes nothing | M08 (same label) | |
| `[<id>] manifest: ...`, `[<id>] USS refreshed for this delivery`, `[<id>] stage blank after delivery` and `[<id>] bridge: one stage row per table row`, for every delivery | M01 (same labels) | 48 assertions |
| the 16 `reuse:` assertions | M09 (same labels) | the shared block |

Unplaced assertions: none.

## v3_activity-schema

Before: 139 assertions. After: 153 (36 core, 117 model). The 14 new ones
are all core: C01.1, C02.2, C02.3, C04.4, C05.4, C06.1, C07.1, C07.3,
C07.4, C08.3, C08.4, C12.1, C13.2, C14.1.

The lifecycle paths (D7), the same-extract tiebreak (D8) and the second
rebuild run live in PART 2 (M10 to M12), after the core, in the same
order as before. D7 restores C002, so they must come after C14.

| Old label | New place | Note |
|---|---|---|
| only the two streams hold warehouse data | M02 (same label) | evaluated after init |
| streams carry every Activity Schema 2.0 column | M02 (same label) | evaluated after init |
| every other column is implementation-specific (spec: '_' prefix) | M02 (same label) | evaluated after init |
| baseline: 2 customers, 3 products, 2 orders current | C02.1 | merged: the core assertion also counts the 3 order lines |
| baseline: C001 email v1 | M03 (same label) | |
| snapshot -> activities: C001 signed_up, then placed_order | M04 (same label) | |
| EVENT TIME: signed_up is stamped with signup_date, not the load | M05 (same label) | |
| EVENT TIME: placed_order is stamped with placed_at | M05 (same label) | |
| placed_order carries revenue_impact and link | M04 (same label) | |
| order lines are product activities: 3 was_ordered, linked to their order | M04 (same label) | |
| was_ordered borrows the order's placed_at (event time) | M05 (same label) | |
| SOFT RULE ON READ: stream stores raw 'P', v_order decodes PENDING | M07 (same label) | |
| lineage: every activity names its delivery | M04 (same label) | |
| a changed attribute is ONE new activity: updated_email | M04 (same label) | |
| updated_email carries only the attribute it owns | M04 (same label) | |
| OBSERVED TIME: the change is stamped with the extract it was seen in | M05 (same label) | |
| unchanged name and signup_date -> NO activity (NOCHANGE) | C03.4 | |
| INCREMENTAL: C002 NOT deleted (60-day stale) | C03.2 | |
| INCREMENTAL: C002 zero activity | C03.3 | |
| LAST EVER: current email is the new one | C03.1 | |
| LAST BEFORE: O-100 still reads the email as it was when placed | M06 (same label) | |
| FULL: SKU-3 discontinued, basis FULL_ABSENCE | M04 (same label) | |
| FULL: absence is stamped with the snapshot's extract date | M05 (same label) | |
| FULL: SKU-3 gone from v_product | C04.2 | |
| FULL: SKU-1 price 8.99 via one updated_price activity | C04.1 | |
| FULL: SKU-2 unchanged -> NOCHANGE, no catalogue activity | C04.3 | |
| D2 wrote exactly two activities (repriced SKU-1, discontinued SKU-3) | M04 (same label) | |
| the discontinued product's order history is untouched | M04 (same label) | |
| tombstone: C002 was_deleted, basis TOMBSTONE | C05.1 | |
| tombstone: C002 gone from v_customer (no ghost row) | C05.2 | |
| tombstone: O-101 placed_by now NULL (current owner is deleted) | C05.3 | |
| LAST BEFORE: O-101 at purchase still answers Bob Jones | C05.5 (Q7) | |
| history survives the delete: C002's activities are all still there | M04 (same label) | |
| recency: newest email wins (not MAX) | C06.2 | |
| recency: two staged rows -> one signed_up, no spurious update | M04 (same label) | |
| dup file skipped: streams unchanged | C07.2 | |
| reconcile: C003 deleted by absence (FULL) | C08.1 | |
| reconcile: C002 already deleted -> not deleted twice | M04 (same label) | |
| reconcile: D5 wrote exactly one activity (the C003 delete) | M04 (same label) | |
| reconcile: v_customer shows only C001 | C08.2 (Q1) | |
| re-asserted current state writes zero activities | C09.1 | |
| FIRST EVER / FIRST AFTER (x2) / journeys survive deletes / no foreign keys anywhere | M06 (same labels) | 5 assertions, evaluated after D5R as before |
| UPDATE on customer_stream aborts | M08 (same label) | |
| DELETE on product_stream aborts | M08 (same label) | |
| activity_id and _seq are dense and unique per stream | M08 (same label) | |
| archive captured every delivered row | C10.1 | |
| only differences become activities: fewer customer activities than staged customer rows + orders | M08 (same label) | |
| UPDATE on hist_customer aborts | C10.2 | |
| DELETE on hist_order aborts | C10.3 | |
| clean+rebuild: streams identical (activity_id, ts, _seq, lineage included) | C11.1 | |
| live ref change is visible immediately in v_order | M07 (same label) | evaluated in C12; C12.1 (Q9) separately reads every order activity |
| ...while the stream still holds the raw code | M07 (same label) | evaluated in C12 |
| repoint: order_reassigned lands in C001's stream | M09 (same label) | |
| repoint: it records where the order came from | M09 (same label) | |
| repoint: C002's placed_order is untouched (immutable) | M09 (same label) | |
| repoint: unchanged order attributes -> no order_updated | M09 (same label) | |
| repoint: placed_by resolves to Alice Smith | C13.1 (Q8) | merged: Q8 lists every current owner |
| repoint: LAST BEFORE at purchase still Bob Jones | M09 (same label) | |
| repoint: ownership read against each activity's own moment | M09 (same label) | C13.2 separately asks for the earlier owner |
| re-asserted repoint writes nothing | M09 (same label) | |
| the seven lifecycle assertions (D7) | M10 (same labels) | live in PART 2 |
| the four ordering assertions (D8) | M11 (same labels) | live in PART 2 |
| clean+rebuild after re-point, lifecycle and tiebreak: streams identical | M12 (same label) | live in PART 2 |
| `[<id>] manifest: ...`, `[<id>] stage blank after delivery` and `[<id>] every activity is in the catalog`, for every delivery | M01 (B0 to D6R) and inline in M10, M11 (D7, D8) | 47 assertions |
| the 16 `reuse:` assertions | M13 (same labels) | the shared block |

Unplaced assertions: none.

## v3_one-big-table

Before: 71 assertions. After: 85 (36 core, 49 model). The 15 new ones are
all core: C01.1, C02.2, C02.3, C03.3, C03.4, C04.3, C04.4, C05.1, C05.4,
C05.5, C06.1, C07.1, C07.4, C12.1, C14.1.

**OBT keeps only the latest state.** Its history answers (Q2, Q3, Q4, Q7,
and C03.4, C05.1, C05.4, C13.2) are queries over the archived log, which
is the model's own way of keeping history; the answer files that need the
archive say so in their header, and the suite runs them with it attached.
"Writes nothing" (C03.3, C04.3, C09.1) means the latest tables are
unchanged; that the log still grows is a model assertion (M04), as the
plan decided for C09.

**C12 Rule change** is new for OBT. The rule lives in the `CASE` of the
`v_order` view, so changing it means redefining that view. The check does
so on a copy of the database, with 'P' relabelled PLACED, and reads every
order through Q9; the shipped schema is untouched.

| Old label | New place | Note |
|---|---|---|
| baseline: 2 customers, 3 products, 2 orders | C02.1 | merged with the next into one count of customers, products, orders and lines |
| baseline: the wide table is at order-line grain (3 rows) | C02.1 | merged, as above |
| baseline: C001 email v1 | M02 (same label) | |
| raw code stored, translated per-consumer in the view | M03 (same label) | |
| latest: C001 email updated | C03.1 | |
| INCREMENTAL: C002 NOT deleted (60-day stale) | C03.2 | |
| INCREMENTAL: C002 email unchanged | M02 (same label) | |
| FULL: SKU-3 deleted by absence (a later FULL outranks its last mention) | C04.2 | |
| FULL: SKU-1 price 8.99 | C04.1 | |
| NO NOCHANGE SUPPRESSION: unchanged SKU-2 stored again anyway (2 archive rows) | M04 (same label) | |
| tombstone: C002 gone from the latest table | C05.2 | |
| tombstone: O-101 placed_by now NULL | C05.3 | |
| Bob survives ONLY in the log (no model keeps him queryable) | M04 (same label) | |
| recency: newest email wins (not MAX) | C06.2 | |
| dup file skipped: latest tables unchanged | C07.2 | |
| dup file skipped: archive unchanged | C07.3 | merged and stricter: it counted customer rows; C07.3 compares every archive table and the manifest |
| reconcile: C003 deleted by absence (FULL) | C08.1 | |
| reconcile: only C001 remains | C08.2 (Q1) | |
| reconcile: C002 stays deleted (tombstone still outranked by nothing) | C08.3 (Q2) | merged and stricter: Q2 requires C002 and C003, and nobody else |
| re-asserted state: latest tables unchanged | C09.1 | |
| ...but the archive grew by the full re-delivery (+1 wide row) | M04 (same label) | |
| archive captured every delivered row | C10.1 | |
| UPDATE on hist_customer aborts | C10.2 | |
| DELETE on hist_order aborts | C10.3 | |
| clean+rebuild: identical latest tables from the log alone | C11.1 | |
| C001's email history recovered via LAG over the archive | C08.4 (Q3) | the same LAG query, now `answers/Q3.sql`, asked after D5 instead of after the rebuild (the log holds the same rows) |
| repoint: O-101 now belongs to C001, effortlessly | M05 (same label) | |
| repoint: placed_by resolves to Alice Smith | C13.1 (Q8) | merged: Q8 lists every current owner |
| repoint: the prior pairing survives only in the log | C13.2 | |
| `[<id>] manifest: ...` and `[<id>] stage blank after delivery`, for every delivery | M01 (same labels) | 26 assertions |
| the 16 `reuse:` assertions | M06 (same labels) | the shared block |

Unplaced assertions: none.

## v3_focal-point

Before: two suites, `run_tests.sh` (142 assertions, plus 2 known gaps)
and `test_archive.sh` (48). After: one suite, 213 assertions (36 core, of
which 1 is a GAP; 177 model). `tests/test_archive.sh` is gone: its
rule-change check is now core C12.1, and every other check is a MODEL
section (M10 to M21), running on its own database pair as before. The 22
new core assertions are C01.1, C02.1, C02.2, C02.3, C03.4, C04.3, C04.4,
C05.3, C05.4, C05.5, C06.1, C07.1, C07.3, C07.4, C08.2, C08.4, C10.1,
C10.2, C10.3, C11.1, C13.2 and C14.1.

**Core GAP, C13.1 "O-101 is owned by Alice Smith and nobody else".** This
is Focal's known driving-key re-point gap. Q8 lists every active pairing,
so it reads "Alice Smith,Bob Jones". The two old expected failures
("desired: exactly ONE active pairing", "desired: the active pairing is
C001") are merged into it: Q8 passes only when both hold. The suite now
reports 1 gap where it reported 2, and prints the suggested fix in M06.

| Old label | New place | Note |
|---|---|---|
| baseline: 2 customers / 3 products | M02 (same labels) | focal-table counts; C02.1 counts the current views and order lines |
| baseline: C001 email v1 | M02 (same label) | |
| INCREMENTAL: C001 email updated | C03.1 | |
| INCREMENTAL: C002 NOT deleted (60-day stale) | C03.2 | |
| INCREMENTAL: C002 email unchanged | M02 (same label) | |
| INCREMENTAL: C002 no version churn (1 row) | C03.3 | |
| INCREMENTAL: still 2 customers | M02 (same label) | |
| existence: D1's window writes no existence row for absent C002 (ACTIVE once) | M04 (same label) | |
| FULL: SKU-3 deleted on absence | C04.2 | |
| FULL: SKU-3 key still exists | M02 (same label) | |
| FULL: SKU-1 price changed 8.99 | C04.1 | |
| tombstone: C002 now deleted | C05.1 | |
| tombstone: C002 gone from v_customer | C05.2 | |
| recency: newest email wins (not MAX) | C06.2 | |
| dup file skipped: desc rows unchanged | C07.2 | merged and stricter: it counted `customer_desc`; C07.2 compares every data table |
| dup file: D1 recorded once / D1 archived once | M05 (same labels) | |
| existence: re-delivered ACTIVE C003 writes nothing (NOCHANGE) / C003 is still ACTIVE once | M04 (same labels) | the D4R re-send runs where it did, in C07 |
| reconcile: C003 deleted by absence (FULL) | C08.1 | |
| reconcile: C001 survives | M02 (same label) | |
| reconcile: C002 stays deleted | C08.3 (Q2) | merged and stricter: Q2 requires C002 and C003, and nobody else |
| the eight "Existence after D5" assertions (end state, v_customer_status x2, SKU-3 x2, existence history, email history, v_all_facts) | M04 (same labels) | the end-state one stays here; C14.1 asks the same after the re-point |
| C002 survived the incremental window, only died to a tombstone | M03 (same label) | |
| replay: zero new data rows / loaded_files / archived rows / pipeline runs | M05 (same labels) | the same-id replay of the whole sequence, still in C09 |
| re-asserted current state writes zero data rows | C09.1 | |
| defect today: O-101 has BOTH pairings active | M06 (same label) | |
| desired: exactly ONE active pairing for the driving key (GAP) | C13.1 (Q8), GAP | merged, as above |
| desired: the active pairing is C001 (GAP) | C13.1 (Q8), GAP | merged, as above |
| the five `restore:` assertions | M07 (same labels) | live in PART 2 |
| the Level 1 and Level 2 assertions | M08, M09 (same labels) | live in PART 2 |
| every `ck_load_control` assertion (`[<id>] loaded_files: ...`, `archive: raw rows captured verbatim`, `scope: ...`), for every delivery | M01 (same labels) | |
| the 16 `reuse:` assertions | M22 (same labels) | the shared block |
| **test_archive.sh** section 1 (8 assertions: archive holds every staged row, 6 deliveries COMPLETE, load_seq dense, raw value survives, re-sending D1 x2, reused file_id REJECTED, ...and says why) | M10 (same labels) | |
| test_archive.sh section 2 (UPDATE/DELETE on each hist_* aborts x8, archive intact) | M11 (same labels) | C10.2 and C10.3 assert the same on the main archive |
| test_archive.sh section 3 (rebuild identical, focal rows repopulated, lineage regenerated) | M12 (same labels) | C11.1 asserts the rebuild on the main warehouse |
| test_archive.sh sections 4, 5, 6 | M13, M14, M15 (same labels) | |
| test_archive.sh section 7: changed meta_value_map is applied retroactively (PENDING -> PLACED) | C12.1 (Q9) | merged and stricter: it read O-100's status; Q9 reads every open status version of every order |
| test_archive.sh sections 8 to 13 | M16 to M21 (same labels) | |

Unplaced assertions: none.

## v3_anchor

Before: 124 assertions. After: 133 (36 core, 97 model). The 15 new ones
are all core: C01.1, C02.2, C02.3, C03.1, C04.1, C04.4, C05.5, C06.1,
C07.1, C07.3, C07.4, C08.3, C08.4, C13.2, C14.1.

| Old label | New place | Note |
|---|---|---|
| baseline: 2 customers, 3 products, 2 orders in the perspectives | C02.1 | merged: the core assertion also counts the 3 order lines |
| baseline: deterministic anchor IDs (C001=1001, C002=1002) | M02 (same label) | |
| baseline: C001 email v1 | M02 (same label) | |
| baseline: typed column (Product_Price is REAL, not a slot) | M03 (same label) | |
| KNOT: raw 'P' in the archive, knot label PENDING on read | M04 (same label) | |
| ATTRIBUTE GRAIN: C001 email has 2 rows... | M03 (same label) | |
| ...but C001 name still has 1 (only what changed is versioned) | C03.4 | |
| INCREMENTAL: C002 NOT deleted (60-day stale) | C03.2 | |
| INCREMENTAL: C002 zero churn anywhere | C03.3 | |
| restatement control: C001 EXISTS not re-asserted | M03 (same label) | |
| FULL: SKU-3 DELETED by absence (existence is data, not row_st) | M05 (same label) | |
| FULL: SKU-3 attributes untouched by its deletion | M03 (same label) | |
| FULL: SKU-3 excluded from v_product | C04.2 | |
| FULL: SKU-1 price 8.99 as a second PRC row | M03 (same label) | C04.1 reads the price itself |
| FULL: SKU-2 zero churn | C04.3 | |
| tombstone: C002 DELETED | C05.1 | |
| tombstone: C002 gone from v_customer | C05.2 | |
| tombstone: O-101 placed_by now NULL | C05.3 | |
| tombstone: Bob's history intact | C05.4 | merged and stricter: now checks the email as well as the name |
| recency: newest email wins (not MAX) | C06.2 | |
| recency: one delivery -> one EML row | M03 (same label) | |
| dup file skipped: constellation unchanged | C07.2 | |
| reused file_id with different content is REJECTED | M06 (same label) | Anchor's same-row-count tamper file is kept; C07.4 uses the shared two-row one |
| reconcile: C003 DELETED by absence (FULL) | C08.1 | |
| reconcile: C002 stays DELETED, no re-assertion (still 2 rows) | M05 (same label) | |
| reconcile: C001 full snapshot, zero attribute churn | M03 (same label) | |
| reconcile: v_customer shows only C001 | C08.2 (Q1) | |
| re-asserted current state writes zero rows | C09.1 | |
| archive captured every delivered row | C10.1 | |
| UPDATE on hist_customer / hist_product / hist_order / hist_order_line aborts | C10.2 | merged: one core assertion covers all four tables |
| DELETE on hist_customer / hist_product / hist_order / hist_order_line aborts | C10.3 | merged: one core assertion covers all four tables |
| clean+rebuild: identical, anchor surrogates included | C11.1 | |
| make rebuild exits 0 / every anchor surrogate / constellation identical / archive layout x2 | M07 (same labels) | |
| relabel: every order reads PLACED instantly, no reload | C12.1 (Q9) | merged and stricter: it read the distinct status; Q9 lists every status row of every order |
| ...and rebuild resets it: schema seed is the source of truth | M04 (same label) | |
| unknown status code 'X' is REJECTED / stays STARTED / staged rows preserved | M08 (same labels) | evaluated in C12, as before |
| repoint: O-101 pairing history has 2 rows | M09 (same label) | |
| repoint: exactly one current, and it is C001 | M09 (same label) | |
| repoint: old pairing end-dated by LEAD, never updated | M09 (same label) | C13.2 asks for the earlier owner |
| repoint: placed_by resolves to Alice Smith | C13.1 (Q8) | merged: Q8 lists every current pairing |
| repoint: restatement control kept every attribute silent | M09 (same label) | |
| re-asserted repoint writes nothing | M09 (same label) | |
| same anchor surrogates / same constellation from the old narrow files | M10 (same labels) | live in PART 2 |
| ingest / after rebuild: tiebreak | M11 (same labels) | live in PART 2 |
| the Level 1 and Level 2 assertions | M12, M13 (same labels) | live in PART 2 |
| `[<id>] manifest: ...` and `[<id>] stage blank after delivery`, for every delivery | M01 (same labels) | |
| the 16 `reuse:` assertions | M14 (same labels) | the shared block |

Unplaced assertions: none.

## v3_metrics-mart

Before: 222 assertions. After: 237 (36 core, of which 1 is a GAP; 201
model). The 18 new core assertions are C01.1, C02.2, C02.3, C03.3, C04.3
(GAP), C05.2, C05.5, C06.1, C07.3, C07.4, C08.2, C08.3, C08.4, C09.1,
C10.1, C12.1, C13.2, C14.1. The C09 re-send (D5R) adds four per-delivery
model checks.

**The raw archive answers what the mart updated away.** The mart keeps
current state only: C08.4 (C001's email history, `answers/Q3.sql`) and
C13.2 (O-101's earlier owner) are answered from the raw archive, the
final answer in every model.

**One core GAP, C04.3 "unchanged SKU-2 writes nothing".** An unchanged
price seen again is a new sample by design (metrics are observations);
name and currency wrote nothing. The GAP prints its reason and the suite
exits 0.

**Ordering changes, no change in meaning.**
- **C13 Re-point** now comes right after the rebuild, ahead of the stale-
  FULL, tiebreak and closed-code-table fixtures (which add customers and
  so had to follow C14). Those run live in PART 2 (M09 to M11), in their
  old order relative to each other, followed by D8 to the end as before.
- **C12 Rule change** relabels 'P' on a copy of the mart. The mart's own
  relabel ("relabel: every pending order reads PLACED instantly") still
  runs live in M19, after the second rebuild, so the later "rebuild resets
  both" check keeps its meaning.

| Old label | New place | Note |
|---|---|---|
| baseline: 2 customers, 3 products, 2 orders in the perspectives | C02.1 | merged: the core assertion also counts the 3 order lines |
| baseline: one RES table / deterministic res_id / providers / aliases / C001 email v1 / batch_no | M02 (same labels) | |
| the five `METRIC:` assertions | M03 (same labels) | |
| PARENT: O-100's parent / CODE TABLE x2 | M04 (same labels) | |
| the five `GROUPS:` and two `TYPE GROUPS:` assertions | M05 (same labels) | |
| the three D0 and three D2 `AGGREGATES:` assertions | M06 (same labels) | |
| stale-window trap: absent C002 is NOT deleted | C03.2 | |
| C001 email updated | C03.1 | |
| CURRENT STATE x2, CURRENT FEEDS ONLY | M07 (same labels) | |
| CHANGED ROWS ONLY: res_customer restamped, RES row for C001 untouched | C03.4 | |
| FULL absence: SKU-3 deleted (res_status = 0) / router staged it as load_oper = 'D' | M07 (same labels) | |
| no ghost row: deleted SKU-3 is out of v_product | C04.2 | |
| SKU-3 keeps its samples / OBSERVATION: unchanged SKU-2 price seen again is a NEW sample / ...but its unchanged name and currency wrote nothing | M03 (same labels) | C04.3 is the GAP they explain |
| SKU-1 current price is the newest sample | C04.1 | |
| SKU-1 price history is two samples | C04.4 (Q4) | |
| tombstone: C002 deleted | C05.1 | |
| tombstone: the row is kept with its last-known name | C05.4 | merged and stricter: now checks the email as well as the name |
| tombstone: O-101 survives, placed_by is NULL (owner not live) | C05.3 | |
| tombstone: O-101 still points at C002 (parent_res is not cleared) | M04 (same label) | |
| recency dedup: newest extract wins, not MAX(value) | C06.2 | |
| new resource continues the surrogate sequence (C003 = 8) | M02 (same label) | |
| load control: duplicate delivery skipped | C07.1 | |
| load control: the mart is unchanged | C07.2 | |
| FULL reconciliation: C003 deleted by absence | C08.1 | |
| NOCHANGE: C001 restated unchanged writes nothing / already-deleted C002 not restamped / END STATE x3 | M07 (same labels) | |
| archive rejects UPDATE / DELETE (hist_customer), and on each of the other three tables | C10.2, C10.3 | merged: one core assertion each covers all four tables |
| a used file_id with different content is rejected | M08 (same label) | |
| rebuild: census identical | C11.1 | merged with the next: C11.1 compares the census and the full snapshot |
| rebuild: every surrogate, value and srcd_ts identical | C11.1 | merged, as above |
| make rebuild exits 0 / make rebuild identical / archive layout x2 | M08 (same labels) | |
| repoint: O-101's parent is now C001 / unchanged status, currency and placed_at wrote nothing | M04 (same labels) | |
| repoint: placed_by resolves to Alice Smith | C13.1 (Q8) | merged: Q8 lists every current owner |
| repoint: IN PLACE -- the mart no longer knows C002 ever owned it / ...the archive does / re-asserted repoint writes nothing | M07 (same labels) | C13.2 asks the archive for the earlier owner by name |
| repoint: the restated amount is a new observation (2 samples) | M03 (same label) | |
| every assertion of the stale-FULL, tiebreak and closed-code-table sections | M09, M10, M11 (same labels) | live in PART 2 |
| every assertion from "Price observation" through "Level 2: the narrow loaders" | M12 to M25 (same labels) | live in PART 2, same order |
| `[<id>] manifest: ...`, `[<id>] stage blank after delivery`, `[<id>] integrity views empty`, for every delivery | M01, or inline in PART 2 | |
| the 16 `reuse:` assertions | M26 (same labels) | the shared block |

Unplaced assertions: none.

## Changed before alignment

These assertions changed in earlier steps, and are listed here so the
mapping for runs 2 to 4 starts from the right text.

- **Data Vault (C2d, 17 November 2026).** The three baseline hub counts
  ("baseline: 2 customer keys", "baseline: 3 product keys", "baseline: 2
  order keys") and the hub and satellite rows of `census()` exclude the
  reserved keys `'0'`, `'-1'` and `'-2'`.
- **Focal (C2e, 17 November 2026).** "tombstone: C002 gone from
  v_customer" and "reconcile: C002 stays deleted" (`run_tests.sh`), and
  "replay: C002 still deleted by tombstone" (`test_archive.sh`), assert
  that `v_customer` has no row for C002, where they used to accept an
  empty email.
