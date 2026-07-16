# One Big Table — the null hypothesis

The no-model position, taken seriously: the append-only delivery log **is**
the warehouse, and everything queryable is a full-refresh recomputation
over it (the dbt-style full refresh / functional data engineering pattern —
idempotent by construction, no incremental state anywhere). Same wide
deliveries as DV, Kimball and Inmon, byte-identical.

```bash
make demo     # fresh archive + the full delivery sequence + tables
make rebuild  # init + ONE refresh -- no replay loop, nothing incremental
make test     # 55 assertions, mutation-hardened
```

This demo exists to answer the question the other five raise:
**what does modeling actually buy?**

## What it gets right, embarrassingly cheaply

- **Every shared scenario passes.** The stale-window trap, tombstones, FULL
  reconciliation, recency dedup, even the D6 re-point (latest simply wins)
  — all computed by one query per feed in
  [refresh_latest.sh](scripts/refresh_latest.sh). The mode-aware delete
  rule is *derived from the log* rather than enforced during loading: a key
  is deleted if its latest mention is a tombstone, or if any FULL delivery
  of its feed came after that mention (had the key been in that snapshot,
  *that* would be the latest mention).
- **Rebuild is trivial** — init plus one refresh — precisely because
  nothing was ever derived incrementally. The other five demos work hard
  for replay determinism; here it is free.
- **`obt_order_wide`** is the pattern's namesake: order-line grain,
  everything denormalized, the table every BI tool wishes it had.

## Where the bill arrives, asserted by tests

1. **No NOCHANGE concept.** D2's unchanged SKU-2 is stored again in full
   (2 archive rows); a re-delivered D5 under a new file id grows the
   archive while changing nothing. Every sibling demo suppresses this;
   OBT's storage grows with *deliveries*, not with *change*.
2. **History is a query, not a table.** C001's email timeline is
   recoverable — via `LAG` over the log with the correct three-column
   ordering. It works, and the suite proves it, but every history question
   is that query, written again, by every consumer, correctly, every time.
   Deleted Bob survives *only* in the log; nothing keeps him queryable.
3. **Semantics live in views or nowhere.** The P→PENDING rule is a `CASE`
   in `v_order`. Consumers who query `obt_orders` directly get raw codes.
   There is no model layer to state a rule once.
4. **The transform's complexity is data.** `refresh_latest.sh` re-derives,
   on *every load*, what the other demos compute once per delivery. At six
   deliveries that is invisible; at thousands, the full refresh *is* the
   nightly batch window.

## Honest scorecard vs the other five

Same input, same answers, so the trade is stark: OBT wins on loader
simplicity, rebuild triviality, and time-to-first-query; it loses on
storage growth, history access, single-statement semantics, and refresh
cost at scale. Every one of those losses is exactly the line item some
model in this repo exists to fix — which is the point of keeping the null
hypothesis runnable next to them.

## Layout

```
schema/01_stage.sql       stage (file-ingest surface) + latest tables + views
schema/02_archive.sql     THE warehouse: append-only wide log + manifest
scripts/load_feed.sh      stage -> append -> refresh; shared load control
scripts/refresh_latest.sh the ONE transform: full recomputation over the log
scripts/rebuild.sh        init + one refresh
source/d0..d5*.sql        byte-identical copies of the v3_datavault deliveries
tests/run_tests.sh        55 assertions; mode-filter, ranking-order and
                          skipped-refresh mutations all verified to fail it
tests/fixtures/d6_repoint.sql  the restatement fixture (latest wins here)
```
