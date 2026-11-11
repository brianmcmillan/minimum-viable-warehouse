# Kimball star schema — same deliveries, the dimensional model

The dimensional leg of the model-comparison set. The **same six logical
deliveries** (byte-identical wide files shared with DV, Inmon, HOOK, USS,
Activity Schema and OBT) flow into a
Kimball star: SCD Type 2 dimensions, a generated `dim_date`, a decode
dimension, transaction-grain facts — and an **archive** (Kimball's persistent
staging area) built from the Focal demo's archive pattern, which is what
makes the mart disposable.

```bash
make demo           # fresh archive + the full delivery sequence + the star
make rebuild        # throw the star away; replay the archive to rebuild it
make archive-status # what the archive holds, and where it is growing
make test           # 72 assertions, mutation-hardened
```

## The same core rule, a third mechanism

> **Absence means DELETE only for a FULL delivery**; tombstones delete
> always; INCREMENTAL absence never does.

| event | Focal | Data Vault | Kimball |
|---|---|---|---|
| attribute change | new `_desc` version (per context) | new `_hsat` row (whole-row) | expire current dim row **(UPDATE)** + new SCD2 version |
| delete detected | closing row, `row_st='N'` | `'D'` in a status satellite | expire + **deleted-marker version** (`is_deleted=1`, last-known attrs carried) |
| unchanged re-delivery | `NOCHANGE`, writes nothing | hashdiff match, writes nothing | `diff_str` match, writes nothing |
| "is it deleted?" | inferred from descriptors | latest `sts` per key | `is_deleted` on the current version |

## What the star demonstrates that the others don't

1. **Frozen surrogate keys = point-in-time for free.** `fact_orders` stores
   the dimension *version* current at load. After C001's email change, O-100
   still joins to `alice@example.com` — and after C002 is deleted,
   `mart_orders` answers **both** `placed_by_at_purchase = 'Bob Jones'` and
   `placed_by_current = NULL`. Focal and DV need explicit history queries
   (or PIT structures) for the first answer; the star gets it from a plain
   equi-join, which is the entire query-performance argument for Kimball.
2. **Type 1 vs Type 2, side by side.** `dim_order_status` is a Type 1 decode:
   `UPDATE ... SET status_name='PLACED'` and every fact reads the new label
   instantly. `dim_customer` is Type 2: changes version. The test suite also
   shows the sharp edge: **`make rebuild` resets Type 1 overlays** to the
   schema seed — in an archive-rebuilt world, ad-hoc Type 1 updates are lost
   unless they live in the seed. That is a real operational lesson, not a
   demo artifact.
3. **Facts are UPDATED in place.** The D6 re-point fixture becomes an
   `UPDATE fact_orders SET customer_key=...` — the only in-place fact restatement
   in the set (Inmon also UPDATEs, but only to close a version). The prior pairing survives *only* in the archive
   (`hist_order` still holds O-101→C002). Kimball trades in-database history
   of facts for query speed and leans on the archive for audit.

## What it gives up (and where the others win)

- **History lives in dimensions, not facts.** A restated amount simply
  overwrites. DV's insert-only satellites and Focal's version rows keep
  every state queryable in the warehouse itself; here you must go to the archive.
- **Schema evolution is DDL + ETL edits**, same as DV: a new attribute means
  `ALTER TABLE dim_*`, stage view changes, loader changes. Focal adds a
  metadata row.
- **In-place mutation forfeits trivial auditability.** `row_exp_ts`/
  `is_current` updates and fact restatements cannot be replayed *from the
  mart* — only the archive makes `make rebuild` possible. Without an archive this
  design is unrecoverable; that is exactly why Kimball practice grew one.

## The archive is the Focal archive, applied to Kimball

Same properties, same proofs, same tests:

- **Append-only absolutely** — triggers with no unlock path; `INSERT OR
  IGNORE` re-archiving; a reused `file_id` with different row count is
  rejected.
- **Self-describing** — `load_seq` + `batch_ts` denormalised onto every row;
  the archive replays even if the mart file is destroyed.
- **Complete ⇒ keys reproduce.** Dimension surrogates are rowids assigned
  under `ORDER BY <business key>` inserts, so ordered replay regenerates
  identical keys — asserted byte-for-byte by the rebuild-fidelity test,
  including SCD2 validity windows. Prune one delivery and that promise dies
  (the argument in Focal's
  [Why there is no retention policy](../v3_focal-point/FOCALPOINT.md#why-there-is-no-retention-policy)
  applies unchanged).
- **`make clean` never touches `archive/`**; only `make clean-archive` does.

One structural rule carried over from the Focal work: **ingest and replay
share `apply_delivery.sh`.** A green rebuild therefore proves the real
loaders reproduce the real ingest, not that a separate replay path works.

## Star membership vs the sibling demos' views

`mart_customers` / `mart_products` / `mart_orders` mirror the sibling demos'
business views column-for-column (with `placed_by_current` as the matching
column). End state after D0–D5 matches the rest of the set: C001 alive with
`alice@newmail.com`, C002/C003 deleted, SKU-3 discontinued, SKU-1 at 8.99.
(Focal's `v_customer` still lists deleted customers as ghost rows; see the
[top-level README](../README.md).)

## Layout

```
schema/01_stage.sql      stage L1 (shared shape with v3_datavault) + L2 views
schema/02_archive.sql    raw layer: wide history + manifest + triggers
schema/03_dimensions.sql SCD2 dims, generated dim_date, seeded decode dim
schema/04_facts.sql      fact_orders, fact_order_lines, comparison views
scripts/load_feed.sh     driver: stage → archive → apply, clear-on-success
scripts/apply_delivery.sh one shared path for ingest AND replay
scripts/load_dims.sh     SCD2: expire → new versions → deleted markers
scripts/load_facts.sh    insert new, UPDATE restated, unknown members (-1)
scripts/rebuild.sh       replay the archive in load_seq order
source/d0..d5*.sql       byte-identical copies of the v3_datavault deliveries
tests/run_tests.sh       72 assertions; FULL-guard, replay-order and SCD2
                         churn-guard mutations all verified to fail it
tests/fixtures/d6_repoint.sql  the restatement fixture (fact UPDATE here)
```
