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
| the other nine | runs 2 to 4 | | | | |

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
