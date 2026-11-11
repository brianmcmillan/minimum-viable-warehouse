# Focal — a metadata-driven data warehouse in SQLite and bash

A small, fully working data warehouse built from nothing but **`sqlite3`, `bash`, and `make`**.
No Python, no dbt, no server, no dependencies to install. Clone it, run `make demo`, and you have
a warehouse that ingests multi-source feeds, versions every fact bi-temporally, handles deletes
safely under real feed cadences, and can throw its entire derived state away and rebuild it —
surrogate keys and all — from an append-only raw archive.

It exists to make a few normally-abstract data-warehousing ideas **executable and testable** in
under 1,000 lines of shell and SQL:

- A **generic, metadata-driven schema** where meaning lives in metadata rows, not in columns.
  You add a business attribute by inserting a metadata row, never by altering a table.
- **Ingestion strategy as a property of the source.** A feed is declared `FULL` or `INCREMENTAL`,
  and that single fact decides whether a record's *absence* from a delivery means "deleted."
- A **disposable warehouse over a durable raw layer.** Everything queryable is derived and can be
  regenerated on demand; the only thing that must never be lost is the raw input, captured verbatim.

> **Part of a nine-model comparison set.** This is the metadata-driven,
> narrow (EAV) leg, and the origin of the archive discipline the others
> share. The same six logical deliveries run through nine warehouses
> ([Inmon 3NF EDW](../v3_inmon-3nf), [Kimball star](../v3_data-marts),
> [Data Vault 2.0](../v3_datavault), this Focal Point,
> [Anchor](../v3_anchor), [HOOK](../v3_hook),
> [Unified Star Schema](../v3_unified-star-schema),
> [Activity Schema](../v3_activity-schema), and
> [One Big Table](../v3_one-big-table)), so every difference between them is
> the *model*, never the input. This model takes the narrow,
> one-row-per-attribute originals shared byte-for-byte by Focal Point and
> Anchor. Its archive uses the same narrow layout (`loaded_files` +
> `source_landing_history`, append-only triggers) as the
> [Anchor](../v3_anchor) archive. **This README stands on its own;**
> [FOCALPOINT.md](FOCALPOINT.md) draws the cross-model comparison.

---

## Requirements

| Tool      | Version used in development | Notes                                    |
|-----------|-----------------------------|------------------------------------------|
| `bash`    | 5.x (also runs on 3.2)      | macOS's built-in bash works              |
| `sqlite3` | 3.51                        | Any modern SQLite with window functions  |
| `make`    | 3.81+                       | GNU Make                                 |

That's the whole list. Everything runs against local files in the project directory.

---

## Quick start

```bash
make demo    # fresh archive + schema + a 6-delivery feed sequence, then print the results
make test    # run both test suites (delete semantics + the raw-layer rebuild guarantees)
```

`make demo` loads six deliveries that stand in for a few weeks of real feeds, then prints the
business-facing views. The reconstructed customer/product/order tables it produces:

```
### Customers
customer_key  customer_ref  customer_name  email              signup_date
------------  ------------  -------------  -----------------  -----------
1001          C001          Alice Smith    alice@newmail.com  2026-01-05
1002          C002
1003          C003

### Orders
order_key  order_ref  status   amount  currency  placed_at         placed_by
---------  ---------  -------  ------  --------  ----------------  -----------
1001       O-100      PENDING  29.49   USD       2026-02-01 10:00  Alice Smith
1002       O-101      PENDING  19.5    USD       2026-02-02 11:30
```

Those readable rows are *reconstructed* — none of that shape is stored physically. See
[How meaning is stored](#how-meaning-is-stored-the-four-table-types) below.

---

## The core idea in one rule

Real feeds don't resend everything every time. A CRM might send a 14-day change window; a product
catalogue might send a full snapshot; an order system might send a 45-day window. If you treat every
delivery as a full snapshot, then "this record wasn't in the file" wrongly reads as "this record was
deleted" — and a customer who simply hasn't changed in 60 days silently disappears.

Focal makes the load strategy explicit per feed and enforces one rule:

> **Absence means DELETE only for a FULL delivery.**
> An INCREMENTAL (windowed) delivery never infers a delete from absence. Deletes in an incremental
> world must arrive either as an explicit **tombstone** (`op='DELETE'`) or be found later by a
> **FULL reconciliation**.

The strategy is declared once per feed, and any single delivery can override it (a normally-incremental
source can send a periodic full):

```sql
-- schema/03_seed_metadata.sql
INSERT INTO meta_source_feed(source_system, source_entity, ingestion_strategy) VALUES
 ('CRM','CUSTOMER'  ,'INCREMENTAL'),   -- 14-day change windows
 ('PIM','PRODUCT'   ,'FULL'),          -- full catalogue snapshot every run
 ('OMS','ORDER'     ,'INCREMENTAL'),   -- 45-day windows
 ('OMS','ORDER_LINE','INCREMENTAL');
```

The loader resolves the effective mode per delivery and only turns on the absence-delete branch when
that mode is `FULL`. Same engine, opposite outcomes — driven only by the delivery's declared mode.

### The demo delivery sequence

`make demo` and `make test` run this exact sequence, and each delivery is there to prove one behaviour:

| #  | Delivery                | Feed / mode                  | What it proves                                                        |
|----|-------------------------|------------------------------|----------------------------------------------------------------------|
| D0 | `d0_baseline.sql`       | all / FULL                   | initial full load of every feed                                      |
| D1 | `d1_cust_win_day60.sql` | CRM.CUSTOMER / INCREMENTAL   | a 14-day window updates C001 and **does not** delete stale, absent C002 |
| D2 | `d2_prod_full_v2.sql`   | PIM.PRODUCT / FULL           | absence **does** delete a discontinued SKU                          |
| D3 | `d3_cust_tombstone.sql` | CRM.CUSTOMER / INCREMENTAL   | an explicit `op='DELETE'` tombstone deletes C002                    |
| D4 | `d4_cust_recency.sql`   | CRM.CUSTOMER / INCREMENTAL   | a repeated attribute resolves to the newest by `extract_ts`         |
| —  | re-send D1              | —                            | a duplicate `file_id` is skipped by load control                    |
| D5 | `d5_cust_yearly_full.sql` | CRM.CUSTOMER / FULL        | a yearly full reconciliation deletes C003, gone at source           |

---

## How meaning is stored: the four table types

Every business entity — CUSTOMER, PRODUCT, ORDER — is stored the same way, as a **triad** of generic
tables, plus one relationship table per relationship. The column shape never changes when you add a
business attribute; new attributes are new **rows**, tagged by a semantic key (`type_key`), never new
columns.

| Table       | Role                    | Holds                                                        |
|-------------|-------------------------|--------------------------------------------------------------|
| `*_focal`   | the entity itself       | exactly one row per surrogate key — the point of reference   |
| `*_idfr`    | natural-key map         | business identifier ⇄ surrogate key, bi-temporal             |
| `*_desc`    | descriptive attributes  | one fact per `type_key`, versioned over time                 |
| `*_x`       | relationship            | connects two focals under a relationship `type_key`          |

A row in `customer_desc` on its own is almost meaningless — it says *"customer 1001, type_key 11,
val_str `alice@newmail.com`."* Meaning arrives only by joining `type_key` back to the metadata, which
says type_key 11 is `CUSTOMER_EMAIL`. That indirection is the whole point: the **read model** is a set
of views that decode the generic rows, so relabelling `CUSTOMER_EMAIL` or adding `CUSTOMER_PHONE` is a
metadata edit, with no DDL and no data migration.

```
                        source deliveries (key/value rows)
                                    │
                     ┌──────────────▼───────────────┐
                     │  source_landing_stage         │  raw delivery lands here
                     │      → source_landing         │  recency-deduped, current per feed
                     └──────────────┬───────────────┘
      meta_* tables  ───drives───►  │  loaders (load_keys / load_desc / load_rel)
      (the catalog)                 ▼
                     ┌──────────────────────────────┐
                     │  *_idfr  *_focal  *_desc  *_x │  generic core (four table types)
                     └──────────────┬───────────────┘
                                    ▼
                     ┌──────────────────────────────┐
                     │  v_customer / v_order / …     │  semantic views = the read model
                     └──────────────────────────────┘
```

The metadata catalog (`meta_entity`, `meta_atomic_context`, `meta_attribute`, `meta_relationship`,
`meta_source_map`, `meta_value_map`, `meta_source_feed`, …) both *defines* the model and *drives* the
loader. Full entity-relationship diagrams for every layer are in [docs/er-diagrams.md](docs/er-diagrams.md).

---

## The two databases: a disposable warehouse over a durable archive

There are **two** SQLite files, and the split is the most important design decision in the project.

- **`build/focal.db`** — the derived warehouse. Everything you query. **Throwaway.**
- **`archive/focal_archive.db`** — the raw layer. Every delivery ever accepted, captured *verbatim
  and before it is applied*, append-only, plus a `loaded_files` manifest of what arrived and in what
  order. **Durable.** It lives outside `build/` precisely so that `make clean` and re-initialisation
  cannot touch it.

Because the raw input is never destroyed, the warehouse is disposable:

```bash
make rebuild   # drop build/focal.db and replay the archive back through the SAME loaders
```

`rebuild` replays every archived delivery, in original ingest order, through the *same* code path that
ingested it (`scripts/apply_delivery.sh` is shared by ingest and replay — if replay had its own path, a
green rebuild would prove nothing about ingest). This buys two things a backup never could:

- **Fix a loader bug.** Correct the code and run `make rebuild`. There is no "restore from backup,"
  because the raw input was never overwritten.
- **Change a business rule retroactively.** Order status is translated `'P' → 'PENDING'` *at ingest*,
  but the raw `'P'` survives in the archive. Edit the rule in `schema/03_seed_metadata.sql`, run
  `make rebuild`, and the entire history is re-derived under the new rule. (A test exercises exactly
  this by flipping `'PENDING'` to `'PLACED'` and rebuilding.)

### Rebuild reproduces surrogate keys exactly — and that is load-bearing

Keys are allocated `MAX(key) + ROW_NUMBER() OVER (ORDER BY idfr)`, which depends on the order
identifiers are first seen. Replaying the archive reproduces every key *identically*, but only because
three orderings are guaranteed and each has a regression test:

1. deliveries replay in `load_seq` (ingest) order;
2. a delivery's rows are restored to staging in `seq_nbr` (original physical) order, because the
   recency-dedup tiebreak reads the staged rowid;
3. the key loader iterates feeds in a fixed order.

This is why there is **no retention policy**: replaying a *subset* of deliveries would reassign every
key, and pruned attributes would be gone for good. The archive is a backup only while it is complete,
so nothing in the project can delete an archived row — the append-only triggers in
`schema/05_archive.sql` have no unlock path. The cost is unbounded growth (FULL feeds re-archive their
whole snapshot every run); `make archive-status` makes that growth visible per feed.

---

## How a delivery flows

A delivery is a plain `.sql` file that inserts key/value rows into `source_landing_stage` (see any file
in [`source/`](source/)). `scripts/load_feed.sh` drives one delivery safely, capturing the raw input
*before* applying it:

1. **Stage** the delivery into `source_landing_stage`.
2. **Load control** — look up the delivery's `file_id`. A `file_id` names a delivery's *content*
   (a batch/version id, not a filename — extractors reuse filenames). If it is already `COMPLETE`,
   skip it. If the same `file_id` reappears with *different* rows, reject it loudly rather than let the
   archive stop describing what was actually applied.
3. **Archive** the staged rows verbatim into the append-only `source_landing_history` (idempotent:
   `INSERT OR IGNORE`, which does not fire the delete trigger, so retries are safe).
4. **Apply** via `apply_delivery.sh` → recency-dedup into `source_landing`, then run the three loaders
   (`load_keys` → `load_desc` → `load_rel`), each of which branches on the effective FULL/INCREMENTAL
   mode.
5. **Mark COMPLETE** only after every loader succeeds. A delivery that crashes half-way stays
   `STARTED` and is retried on the next run, never skipped as done.

De-duplication happens at three levels: the **file** level (a re-sent `file_id` is skipped), the
**row** level (a repeated attribute keeps the newest by `extract_ts`), and the **version** level (an
unchanged fact is classified `NOCHANGE` and writes nothing).

---

## Semantic views (the read model)

Defined in `schema/04_views.sql`, exercised by `scripts/query.sh`:

| View                            | What it gives you                                                    |
|---------------------------------|----------------------------------------------------------------------|
| `v_customer` / `v_product` / `v_order` | one readable row per entity (pivots `type_key` back into columns) |
| `v_*_desc_current`              | the latest active fact per (`*_key`, `type_key`)                     |
| `v_all_facts`                   | every current atomic fact across all entities, decoded via metadata  |
| `v_order_status_history`        | the full bi-temporal timeline of a single attribute                  |
| `v_lineage`                     | each fact traced back to the pipeline run that produced it           |

---

## Make targets

| Target                | Effect                                                                              |
|-----------------------|-------------------------------------------------------------------------------------|
| `make demo`           | fresh archive + schema + the full delivery sequence + printed views                 |
| `make rebuild`        | regenerate the warehouse by replaying the raw layer                                 |
| `make archive-status` | report the raw layer (read-only): deliveries, rows per feed, growth                 |
| `make test`           | run the incremental-semantics suite and the raw-layer/rebuild suite                 |
| `make init`           | recreate the derived warehouse from schema (the archive survives)                   |
| `make clean`          | delete `build/` only — **the archive survives**; `make rebuild` restores it         |
| `make clean-archive`  | delete `archive/` — destroys the raw layer and the ability to rebuild (deliberately separate from `clean`) |

`make archive-status` output looks like:

```
### Archived rows per feed  (FULL feeds dominate growth)
feed            strategy     deliveries  raw_rows  rows_per_delivery
--------------  -----------  ----------  --------  -----------------
CRM.CUSTOMER    INCREMENTAL  5           22        4
PIM.PRODUCT     FULL         2           20        10
OMS.ORDER       INCREMENTAL  1           12        12
OMS.ORDER_LINE  INCREMENTAL  1           6         6
```

---

## Repository layout

```
.
├── Makefile              # the entry point for every workflow
├── FOCALPOINT.md         # design notes: the incremental-aware ingestion model in depth
├── schema/
│   ├── 01_metadata.sql   # the metadata catalog + landing tables
│   ├── 02_data.sql       # the four generic table types (idfr / focal / desc / x)
│   ├── 03_seed_metadata.sql  # seeds the model: entities, attributes, feeds, value maps
│   ├── 04_views.sql      # semantic views — the read model
│   └── 05_archive.sql    # the append-only raw layer (separate database)
├── scripts/
│   ├── lib.sh            # shared helpers; the single choke point for DB access + SQL-injection guards
│   ├── init_db.sh        # (re)create the derived warehouse; preserve the archive
│   ├── load_feed.sh      # ingest ONE delivery safely (stage → archive → apply → complete)
│   ├── apply_delivery.sh # the one path from staged rows to the warehouse (ingest AND replay)
│   ├── load_keys.sh      # surrogate keys + identifiers
│   ├── load_desc.sh      # descriptors: bi-temporal delta with strategy-aware deletes
│   ├── load_rel.sh       # relationships: same safe-delete rule
│   ├── rebuild.sh        # replay the archive to regenerate the warehouse
│   ├── archive_status.sh # report the raw layer
│   └── query.sh          # print the business views
├── source/               # the demo delivery files (D0–D5)
├── tests/
│   ├── run_tests.sh      # delete-semantics suite (FULL vs INCREMENTAL, tombstones, recency)
│   ├── test_archive.sh   # raw-layer suite (append-only, exact rebuild, retroactive rules)
│   └── fixtures/         # extra deliveries used only by tests
├── docs/er-diagrams.md   # ER diagrams for every layer (Mermaid)
├── build/                # generated: the derived warehouse (safe to delete)
└── archive/              # generated: the durable raw layer (do NOT delete lightly)
```

---

## Testing

```bash
make test
```

Two independent suites, pure shell + `sqlite3`:

- **`tests/run_tests.sh`** — delete semantics under a realistic cadence: that an incremental window
  does *not* delete an absent-but-unchanged record, that a FULL snapshot *does* delete on absence, that
  tombstones delete in an incremental feed, recency de-duplication, load control (skip/retry), and full
  idempotence of a replay.
- **`tests/test_archive.sh`** — the raw-layer guarantees: the archive captures every delivery verbatim,
  append-only is absolute, rebuild reproduces the warehouse *exactly* (surrogate keys included), keys
  are derived rather than preserved, recency survives replay, and a changed business rule re-derives
  from the untouched raw values.

Both suites pass with no external setup. The delete-semantics suite additionally reports a **known gap**
(see below) as non-fatal amber lines rather than hiding it.

---

## Known limitation: driving-key re-point

The relationship loader understands three deltas — NEW, tombstone-DELETE, and FULL-absence-DELETE — but
not *re-pointing*. When an incremental delivery moves an order from one customer to another, the new
pairing is inserted and the old one stays active: one order, two live customers, and `v_order.placed_by`
becomes undefined (its subquery picks one with `LIMIT 1` and no `ORDER BY`).

Rather than only document this, the project keeps it **executable**: `tests/fixtures/d7_repoint.sql`
loads the re-point, the suite asserts today's defective state as a regular test, and asserts the
*desired* state as expected failures — amber `GAP` lines with the suggested fix printed beneath them. If
the fix ever lands, those lines flip to a red failure telling you to promote them. The fix itself is
small: declare a driving role per relationship in `meta_relationship`, plus a `del_repoint` step in
`load_rel.sh` mirroring the existing tombstone step.

---

## Going deeper

- **[FOCALPOINT.md](FOCALPOINT.md)** — the incremental-aware ingestion model explained in full: the
  core rule, how deletes happen in an incremental world, why surrogate keys survive a rebuild, and why
  there is no retention policy.
- **[docs/er-diagrams.md](docs/er-diagrams.md)** — entity-relationship diagrams for the conceptual
  model, the core focal-point triad, the metadata catalog, and the source-ingestion layer.
