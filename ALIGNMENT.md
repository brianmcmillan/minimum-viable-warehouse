# Test-suite alignment

Every suite runs in two parts. **Part 1, CORE:** the fourteen sections
C01 to C14, in order, holding only core assertions. Their ids and labels
come from [`tests/core_spec.tsv`](tests/core_spec.tsv) and are the same
in all ten suites; each model supplies its own SQL. **Part 2, MODEL:**
that model's own sections, M01 onwards, holding every other assertion.

`make core-check` (`tests/check_core.sh`) runs the suites and fails if one
misses a core id, emits one twice, or emits them out of order. A suite
ends with:

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
| `v3_data-marts` | run 2 | 35/36 | 65 | 1 core | 88 |
| `v3_datavault` | run 2 | 36/36 | 283 | 0 | 304 |
| `v3_hook` | run 2 | 36/36 | 93 | 0 | 115 |
| the other six | runs 3 and 4 | | | | |

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

Before: 88 assertions. After: 101 (36 core, of which 1 is a GAP; 65
model). The 15 new ones are all core: C01.1, C02.2, C02.3, C03.4, C04.4,
C05.4, C06.1, C07.1, C07.3, C07.4, C08.3, C08.4, C13.1, C13.2 (GAP),
C14.1.

**Core GAP, C13.2 "O-101's earlier owner is still answerable".** The
re-point UPDATEs the fact row in place, so the star no longer holds
O-101's earlier owner; only the raw archive does (asserted in M06,
"repoint: prior pairing survives ONLY in the archive"). The suite prints
it as a GAP with that reason and still exits 0. C4b decides whether to
close it.

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
| repoint: prior pairing survives ONLY in the archive | M06 (same label) | the archive's answer to C13.2, which the star cannot give |
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
