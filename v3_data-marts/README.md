# A Kimball star that can throw itself away

A complete, working **Kimball star schema** — SCD Type 2 dimensions,
conformed facts, a generated date dimension — built from nothing but
**`sqlite3`, `bash`, and `make`**. No Python, no dbt, no server, no
packages to install. The `sqlite3` that ships with macOS is enough. Clone
it, run `make demo`, and you have a dimensional warehouse that ingests
multi-source feeds, versions dimensions safely under realistic feed
cadences, answers point-in-time questions from a *plain equi-join* — and
can delete its entire star and rebuild it, surrogate keys and all, from a
durable **archive** (the raw layer Kimball practice calls a persistent
staging area).

It exists to make a handful of normally-abstract dimensional ideas
**executable and testable** in under a thousand lines of shell and SQL:

- **Point-in-time truth from a plain join.** A fact freezes the dimension
  *version* that was current when it arrived, so "who placed this order,
  as they were at purchase?" needs no history query. That frozen key is
  the entire query-performance argument for Kimball.
- **Ingestion strategy as a property of the delivery.** A delivery is
  declared `FULL` or `INCREMENTAL`, and that one fact decides whether a
  record's *absence* from the file means "deleted" — the difference
  between a working incremental pipeline and quiet data loss.
- **A disposable star over a durable staging area.** Everything you query
  is derived and can be regenerated on demand. The only thing that must
  never be lost is the raw delivery, captured verbatim before anything
  touches it.

> **Part of a nine-model comparison set.** This is the dimensional leg. The
> same six logical deliveries run through nine warehouses
> ([Inmon 3NF EDW](../v3_inmon-3nf), this Kimball star,
> [Data Vault 2.0](../v3_datavault), [Focal Point](../v3_focal-point),
> [Anchor](../v3_anchor), [HOOK](../v3_hook),
> [Unified Star Schema](../v3_unified-star-schema),
> [Activity Schema](../v3_activity-schema), and
> [One Big Table](../v3_one-big-table)), so every difference between them is
> the *model*, never the input. This model takes the wide,
> one-row-per-record restatement shared byte-for-byte by Inmon, Kimball,
> Data Vault, HOOK, USS, Activity Schema and OBT. Its archive uses the same
> layout (`loaded_files` + per-feed `hist_*` tables, append-only triggers)
> as the Inmon, HOOK, USS, Activity Schema and OBT archives. **This README
> stands on its own;** [DATAMART.md](DATAMART.md) draws the cross-model
> comparison.

---

## Requirements

| Tool      | Developed against       | Notes                                   |
|-----------|-------------------------|-----------------------------------------|
| `bash`    | 5.x (also runs on 3.2)  | the built-in macOS bash works           |
| `sqlite3` | 3.51                    | any modern SQLite with window functions |
| `make`    | 3.81+ (GNU Make)        | the stock macOS binary works            |

That is the whole list. Everything runs against local files in this
directory; nothing reaches the network.

---

## Quick start

```bash
make demo           # fresh archive + schema + the full 6-delivery sequence, then print the star
make rebuild        # delete the star; replay the archive to rebuild it — surrogate keys included
make archive-status # what the durable archive holds, and where it is growing
make test           # 72 assertions: delete semantics, SCD2, frozen keys, exact rebuild
```

`make demo` loads six deliveries standing in for a few weeks of real feeds,
then prints the business-facing views. After the whole sequence:

```
### Customers (current, not deleted)
customer_ref  customer_name  email              signup_date
------------  -------------  -----------------  -----------
C001          Alice Smith    alice@newmail.com  2026-01-05

### Orders
order_ref  status   amount  currency  placed_at         placed_by_at_purchase  placed_by_current
---------  -------  ------  --------  ----------------  ---------------------  -----------------
O-100      PENDING  29.49   USD       2026-02-01 10:00  Alice Smith            Alice Smith
O-101      PENDING  19.5    USD       2026-02-02 11:30  Bob Jones
```

Look at `O-101`. `placed_by_at_purchase` is **Bob Jones**; `placed_by_current`
is **blank**. That order was placed by C002, who has since been deleted —
yet the star still answers *who placed it at the time* from the frozen key
on the fact, and *who owns it now* (nobody) from the business key. Both
answers are equi-joins. No bi-temporal query anywhere. See
[What the star buys you](#what-the-star-buys-you-point-in-time-from-a-plain-join).

---

## The core idea, in one rule

Real feeds don't resend everything every time. A CRM sends a 14-day change
window; a product catalogue sends a full snapshot; an order system sends a
45-day window. Treat every delivery as a full snapshot and "this record
wasn't in the file" wrongly reads as "this record was deleted" — and a
customer who simply hasn't changed in 60 days silently disappears.

This demo makes the load strategy explicit **per delivery** and enforces one
rule:

> **Absence means DELETE only for a FULL delivery.**
> An INCREMENTAL (windowed) delivery never infers a delete from absence.
> Deletes in an incremental world arrive as an explicit **tombstone**
> (`op='DELETE'`) or are found later by a **FULL reconciliation**.

The strategy rides on the delivery itself. Every staged row declares its
`op` and `load_mode`, and the loader only switches on the absence-delete
branch when the effective mode is `FULL`:

```sql
-- source/d0_baseline.sql — every row declares op + load_mode
INSERT INTO stg_customer_l1(customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode) VALUES
('C001','Alice Smith','alice@example.com','2026-01-05','2026-02-05','UPSERT','FULL'),
('C002','Bob Jones'  ,'bob@example.com'  ,'2026-01-06','2026-02-05','UPSERT','FULL');
```

Same engine, opposite outcomes, driven only by the declared mode. The rule
is shared across every model in the set; only the *mechanism* differs. Kimball
is one of only two models that UPDATE rows (Inmon's close-and-insert is the
other), and the only one that restates facts in place:

| event | Focal | Data Vault | **Kimball (this demo)** |
|---|---|---|---|
| attribute change | new `_desc` version | new `_hsat` row | **expire the current dim row (UPDATE) + insert a new SCD2 version** |
| delete detected | closing row | `'D'` status satellite | **expire + deleted-marker version** (`is_deleted=1`, last-known attrs carried) |
| unchanged re-delivery | `NOCHANGE`, writes nothing | hashdiff match, writes nothing | **`diff_str` match, writes nothing** |
| "is it deleted?" | inferred from descriptors | latest `sts` per key | **`is_deleted` on the current version** |

### The demo delivery sequence

`make demo` and `make test` run this exact sequence; each delivery earns its
place by proving one behaviour:

| #  | Delivery                  | Feed / mode                | What it proves                                                                    |
|----|---------------------------|----------------------------|-----------------------------------------------------------------------------------|
| D0 | `d0_baseline.sql`         | all / FULL                 | initial full load of every feed                                                   |
| D1 | `d1_cust_win_day60.sql`   | CRM.CUSTOMER / INCREMENTAL | a 14-day window versions C001 (SCD2) and **does not** delete stale, absent C002   |
| D2 | `d2_prod_full_v2.sql`     | PIM.PRODUCT / FULL         | absence **does** delete a discontinued SKU (as a deleted-marker version)          |
| D3 | `d3_cust_tombstone.sql`   | CRM.CUSTOMER / INCREMENTAL | an explicit `op='DELETE'` tombstone deletes C002 in an incremental feed           |
| D4 | `d4_cust_recency.sql`     | CRM.CUSTOMER / INCREMENTAL | adds C003; a repeated attribute resolves to the newest by `extract_dt`            |
| —  | re-send D1                | (same `file_id`)           | load control skips a duplicate delivery (exercised by `make test`)                |
| D5 | `d5_cust_yearly_full.sql` | CRM.CUSTOMER / FULL        | a yearly full reconciliation deletes C003, gone at source                         |

---

## How the star is shaped

Every business entity is modelled the Kimball way: **conformed dimensions**
carry the descriptive context, **facts** carry the measurements and point at
dimensions by surrogate key.

| Table              | Kind                        | Holds                                                                                          |
|--------------------|-----------------------------|------------------------------------------------------------------------------------------------|
| `dim_customer`     | SCD **Type 2** dimension    | one row per *version* of a customer: surrogate key, validity window, `is_current` / `is_deleted` |
| `dim_product`      | SCD **Type 2** dimension    | one row per version of a SKU, same shape                                                        |
| `dim_date`         | generated dimension         | one row per calendar day, smart key `YYYYMMDD`; built once at init, no loader ever touches it   |
| `dim_order_status` | **Type 1** decode dimension | raw source code ⇄ label (`P → PENDING`); seeded, updated in place                              |
| `fact_orders`      | transaction-grain fact      | one row per order; surrogate FKs **frozen** to the versions current at load; **UPDATED** in place on restatement |
| `fact_order_lines` | factless fact               | order × product grain                                                                          |

`order_ref` sits on `fact_orders` as a **degenerate dimension** — the
transaction identity travels on the fact, with no dimension table of its own.

Surrogate keys are `INTEGER PRIMARY KEY` (SQLite rowids). Every loader
inserts `ORDER BY <business key>`, so SQLite assigns rowids in a
deterministic order — which is exactly what lets an ordered replay of the
archive reproduce every key identically (see
[Rebuild reproduces keys](#rebuild-reproduces-surrogate-keys-exactly--and-that-is-load-bearing)).

`diff_str` is the SCD2 change-detection column: the concatenated, trimmed
attribute string of a dimension row. Comparing an incoming row's `diff_str`
against the current version's stored `diff_str` *is* the whole "hash
differencing" mechanism — kept in plaintext here so it stays legible.

```
                     source deliveries (op / load_mode rows)
                                   │
                    ┌──────────────▼───────────────┐
                    │  stg_*_l1        (stage L1)   │  one wide table per feed
                    │      → v_stg_*_l2 (views)     │  recency-dedup + diff_str
                    └──────────────┬───────────────┘
                                   │  load_dims (SCD2)  →  load_facts
                                   ▼
                    ┌──────────────────────────────┐
                    │  dim_*          fact_*        │  the star
                    └──────────────┬───────────────┘
                                   ▼
                    ┌──────────────────────────────┐
                    │  mart_customers / mart_orders │  business-facing views
                    │  v_star_order_lines / …       │
                    └──────────────────────────────┘
```

---

## The two databases: a disposable star over a durable staging area

There are **two** SQLite files, and the split between them is the single most
important design decision in the project.

- **`build/datamart.db`** — the star schema. Everything you query.
  **Throwaway.**
- **`archive/datamart_archive.db`** — the **archive** (raw layer), Kimball's
  persistent staging area. Every delivery
  ever accepted, captured *verbatim and before it is applied*, append-only,
  plus a `loaded_files` manifest of what arrived and in what order.
  **Durable.** It lives outside `build/` precisely so that `make clean` and
  re-initialisation cannot touch it.

Because the raw input is never destroyed, the star is disposable:

```bash
make rebuild   # drop build/datamart.db and replay the archive through the SAME loaders
```

`rebuild` replays every archived delivery, in original ingest order, through
the *same* code path that ingested it — `scripts/apply_delivery.sh` is shared
by ingest and replay. (If replay had its own path, a green rebuild would
prove nothing about ingest.) That buys two things a backup never could:

- **Fix an ETL bug.** Correct the loader and run `make rebuild`. There is no
  "restore from backup," because the raw input was never overwritten.
- **Restructure the model retroactively.** Order status is decoded
  `'P' → 'PENDING'` by a *seeded dimension*, but the raw `'P'` survives in the
  archive. Restructure the decode and run `make rebuild`, and the whole history
  re-derives cleanly. Without the archive, an in-place-mutating star like this
  one is simply unrecoverable — which is exactly why Kimball practice grew a
  persistent staging area.

### Rebuild reproduces surrogate keys exactly — and that is load-bearing

Surrogate keys are rowids assigned under `ORDER BY <business key>` inserts,
so they depend on the order business keys are first seen. Replaying the archive
reproduces every key — and every SCD2 validity window — *identically*, but
only because three orderings are guaranteed, and each has a regression test:

1. deliveries replay in `load_seq` (ingest) order;
2. a delivery's rows are restored to staging in `seq_nbr` (original physical)
   order, because the recency-dedup tiebreak reads the staged rowid;
3. the dimension loader inserts new versions in a fixed `ORDER BY` per feed.

This is why there is **no retention policy**: replaying a *subset* of
deliveries would reassign every key and move version chains. The archive is a
backup only while it is complete, so nothing in the project can delete an
archived row — the append-only triggers in `schema/02_archive.sql` have no unlock
path. The cost is unbounded growth (a FULL feed re-archives its whole
snapshot every run); `make archive-status` makes that growth visible per feed.

---

## How a delivery flows

A delivery is a plain `.sql` file that inserts rows into the `stg_*_l1` stage
tables (see any file in [`source/`](source/)). `scripts/load_feed.sh` drives
one delivery safely, capturing the raw input *before* applying it:

1. **Stage** the delivery into `stg_*_l1`, and record its logical timestamp
   in `mart_load_params`.
2. **Load control** — look up the delivery's `file_id`. A `file_id` names a
   delivery's *content* (a batch/version id, not a filename — extractors
   reuse filenames). If it is already `COMPLETE`, skip it. If the same
   `file_id` reappears with a *different* row count, reject it loudly rather
   than let the archive stop describing what was actually applied.
3. **Archive** the staged rows verbatim into the append-only archive tables —
   idempotent (`INSERT OR IGNORE`, which does not fire the append-only
   triggers, so retries are safe), assigning `load_seq` on first sight.
4. **Apply** via `apply_delivery.sh` → `load_dims.sh` (SCD2: expire → new
   versions → deleted markers) then `load_facts.sh` (insert new, UPDATE
   restated, unknown-member fallbacks). Both branch on the effective
   FULL/INCREMENTAL mode.
5. **Mark COMPLETE** only after every loader succeeds, then clear the stage.
   A delivery that crashes half-way stays `STARTED`, leaves its staged rows
   as forensics, and is retried on the next run — never skipped as done.

De-duplication happens at **three levels**: the **file** level (a re-sent
`file_id` is skipped), the **row** level (a repeated attribute keeps the
newest by `extract_dt` in the `v_stg_*_l2` views), and the **version** level
(an unchanged dimension row matches `diff_str` and writes nothing).

---

## What the star buys you: point-in-time from a plain join

This is the payoff the dimensional model delivers that its insert-only
siblings charge a history query for.

- **Frozen surrogate keys = point-in-time for free.** `fact_orders` stores
  the dimension *version* current at load. After C001's email change, `O-100`
  still joins to `alice@example.com`; after C002 is deleted, `mart_orders`
  answers **both** `placed_by_at_purchase = 'Bob Jones'` and
  `placed_by_current = NULL` — the first from the frozen key, the second from
  the business key. No bi-temporal predicate anywhere. The same effect shows
  on order lines: `O-100`'s line still reads `Widget @ 9.99` even after D2
  reprices SKU-1 to `8.99`, because the line froze the product version it saw.

- **Type 1 vs Type 2, side by side.** `dim_order_status` is a Type 1 decode:
  `UPDATE ... SET status_name='PLACED'` and every fact — past and future —
  reads the new label instantly, no reload. `dim_customer` and `dim_product`
  are Type 2: a change versions the row. The test suite also shows the sharp
  edge — **`make rebuild` resets Type 1 overlays** to the schema seed, because
  in an archive-rebuilt world an ad-hoc Type 1 `UPDATE` that isn't in the seed is
  lost. That is a real operational lesson, not a demo artifact.

- **Facts are UPDATED in place.** When the source restates an order — a
  changed amount, status, or a re-pointed customer — `fact_orders` is
  `UPDATE`d, not versioned. This is the deliberate contrast with the
  insert-only siblings: the star trades in-database history of facts for query
  speed, and the archive is what keeps that honest — every prior state still lives
  in `hist_order`, and `make rebuild` reapplies the whole history.

---

## The read model (views)

Defined in `schema/03_dimensions.sql` and `schema/04_facts.sql`, printed by
`scripts/query.sh`:

| View                                               | What it gives you                                                            |
|----------------------------------------------------|------------------------------------------------------------------------------|
| `mart_customers` / `mart_products`                 | one readable row per current, non-deleted entity                             |
| `mart_orders`                                      | one row per order, with both `placed_by_at_purchase` and `placed_by_current` |
| `v_dim_customer_current` / `v_dim_product_current` | the current version of each dimension                                        |
| `v_customer_history`                               | every SCD2 version of every customer, with its validity window               |
| `v_star_order_lines`                               | the star fully joined: one line per order line, all dimensions decoded       |

`mart_customers` / `mart_products` / `mart_orders` mirror the sibling demos'
business views column-for-column, so `make demo` outputs compare directly
across models.

---

## Make targets

| Target                | Effect                                                                                     |
|-----------------------|--------------------------------------------------------------------------------------------|
| `make demo`           | fresh archive + schema + the full delivery sequence + printed star                         |
| `make rebuild`        | regenerate the star by replaying the archive                                               |
| `make archive-status` | report on the archive (read-only): deliveries, rows per feed, growth                       |
| `make test`           | run the Kimball test suite (72 assertions)                                                 |
| `make init`           | recreate the star from schema (the archive survives)                                       |
| `make clean`          | delete `build/` only — **the archive survives**; `make rebuild` restores the star          |
| `make clean-archive`  | delete `archive/` — destroys the raw history and the ability to rebuild (deliberately separate from `clean`) |

`make demo` rebuilds a fresh archive first, because deliveries are skipped once
`COMPLETE`; it is the only target that discards the archive implicitly.
`make archive-status` output looks like:

```
### Deliveries
load_seq  file_id  batch_ts             status    row_count
--------  -------  -------------------  --------  ---------
1         B0       2026-02-05 08:00:00  COMPLETE  10
2         D1       2026-03-02 08:00:00  COMPLETE  1
...

### Archived rows per feed  (FULL feeds dominate growth)
feed            deliveries  raw_rows  rows_per_delivery
--------------  ----------  --------  -----------------
CRM.CUSTOMER    5           7         1
PIM.PRODUCT     2           5         2
OMS.ORDER_LINE  1           3         3
OMS.ORDER       1           2         2
```

---

## Repository layout

```
.
├── Makefile                # the entry point for every workflow
├── DATAMART.md             # design notes: the star vs the sibling models, in depth
├── schema/
│   ├── 01_stage.sql        # stage L1 tables (shared shape) + L2 dedup / diff_str views
│   ├── 02_archive.sql      # raw layer: per-feed history + manifest + append-only triggers
│   ├── 03_dimensions.sql   # SCD2 dims, generated dim_date, seeded decode dim, current views
│   └── 04_facts.sql        # fact_orders, fact_order_lines, comparison + star views
├── scripts/
│   ├── lib.sh              # shared helpers; the single DB choke point + SQL-injection guards
│   ├── init_db.sh          # (re)create the star; preserve the archive
│   ├── load_feed.sh        # ingest ONE delivery safely (stage → archive → apply → complete)
│   ├── apply_delivery.sh   # the one path from staged rows to the star (ingest AND replay)
│   ├── load_dims.sh        # SCD2: expire → new versions → deleted markers
│   ├── load_facts.sh       # facts: insert new, UPDATE restated, unknown members (-1)
│   ├── rebuild.sh          # replay the archive to regenerate the star
│   ├── archive_status.sh   # report on the archive
│   └── query.sh            # print the star + its signature queries
├── source/                 # the demo delivery files (D0–D5), byte-identical with ../v3_datavault
├── tests/
│   ├── run_tests.sh        # 72-assertion suite (delete semantics, SCD2, frozen keys, exact rebuild)
│   └── fixtures/
│       └── d6_repoint.sql  # restatement fixture: the re-point that becomes a fact UPDATE
├── build/                  # generated: the star (safe to delete)
└── archive/                # the durable raw layer (do NOT delete lightly)
```

---

## Testing

```bash
make test
```

One suite, pure shell + `sqlite3`, **72 assertions**, mutation-hardened (the
FULL-guard, replay-order, and SCD2 churn-guard mutations were all verified to
fail it). It replays the shared delivery scenario against the star and then
exercises the Kimball-specific behaviours:

- **Delete semantics under a realistic cadence** — an incremental window does
  *not* delete an absent-but-unchanged record; a FULL snapshot *does* delete
  on absence (as a deleted-marker version carrying last-known attributes);
  tombstones delete in an incremental feed; recency de-duplication; and load
  control (skip a re-sent `file_id`, retry a crashed one).
- **SCD Type 2** — version counts, exactly one current row per key, validity
  windows closed at the batch timestamp.
- **Frozen surrogate keys** — a fact keeps the dimension version it saw;
  `placed_by_at_purchase` survives a later change and a later delete.
- **Type 1 vs Type 2** — a decode `UPDATE` is read instantly by every fact,
  and a rebuild resets it to the seed.
- **In-place fact restatement** — the D6 re-point becomes an
  `UPDATE fact_orders`; the prior pairing survives *only* in the archive.
- **The archive guarantees** — append-only is absolute, and `make clean` +
  `make rebuild` reproduces the star *exactly*, surrogate keys and SCD2
  windows included.

The suite passes with no external setup.

---

## What the star gives up (and where the siblings win)

The dimensional model is a set of deliberate trade-offs, and the demo keeps
them honest rather than hiding them:

- **History of facts lives in dimensions, not facts.** A restated amount
  overwrites the fact row; only the archive retains the prior state. The
  insert-only siblings keep every fact state queryable *in the warehouse
  itself*.
- **Type 1 overlays are not durable across a rebuild.** An ad-hoc decode
  `UPDATE` that doesn't live in the schema seed is lost when `make rebuild`
  re-derives from the archive.
- **Schema evolution is DDL + ETL edits.** A new attribute means
  `ALTER TABLE dim_*`, a stage-view change, and a loader change — where a
  metadata-driven model would add a row.
- **In-place mutation forfeits trivial auditability.** `is_current` updates
  and fact restatements cannot be replayed *from the mart* — only the archive
  makes `make rebuild` possible. Without an archive this design is unrecoverable;
  that is precisely why it has one.

---

## Going deeper

- **[DATAMART.md](DATAMART.md)** — the design notes: what the star
  demonstrates that the other models don't (point-in-time from frozen keys,
  Type 1 vs Type 2), what it gives up, and how the archive is the Focal archive
  pattern applied to Kimball's persistent staging area. Draws the full
  comparison across the model set.
- **Sibling demos** — [`../v3_datavault`](../v3_datavault) (Data Vault 2.0)
  and [`../v3_focal-point`](../v3_focal-point) (metadata-driven Focal) ingest
  the *same deliveries* and reach the *same end state*, so their READMEs read
  as one study of how each model handles identical input. The
  [top-level README](../README.md) sets out all nine warehouses and the essays
  that argue over how to choose between them.
