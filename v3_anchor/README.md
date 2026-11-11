# Anchor — a 6NF data warehouse in SQLite and bash

A small, fully working [Anchor Modeling](https://www.anchormodeling.com/) warehouse built from nothing
but **`sqlite3`, `bash`, and `make`**. No Python, no dbt, no server, no dependencies to install. Clone
it, run `make demo`, and you have a sixth-normal-form constellation that ingests multi-source feeds,
versions every attribute independently over time, handles deletes safely under real feed cadences, and
can throw its entire derived state away and rebuild it — surrogate keys and all — from an append-only
raw archive.

It exists to make a few normally-abstract Anchor ideas **executable and testable** in under 1,000 lines
of shell and SQL:

- **One table per attribute, each properly typed.** `Product_Price` is a `REAL` column in its own table,
  not a generic value slot. Meaning lives in the schema itself. You add a business attribute by
  `CREATE TABLE`, never by `ALTER`.
- **Presence is data, not a flag.** There is no `row_st` column to flip. Whether an entity exists is
  recorded as assertions in an *existence knot* (`EXISTS` / `DELETED`), versioned like any other
  attribute — so a "deleted then seen again" history is just more rows.
- **A disposable warehouse over a durable raw layer.** Everything queryable is derived and can be
  regenerated on demand; the only thing that must never be lost is the raw input, captured verbatim.

Anchor ships a rich modeling-and-query literature but no loading doctrine — the official tooling
generates DDL and insert triggers, not pipeline discipline. This project brings one: mode-aware deletes,
tombstones, load control, capture-raw-then-apply, and ordered replay, each landing on a natively Anchor
construct. The design notes in **[ANCHOR.md](ANCHOR.md)** walk through every one of those decisions.

> **Part of a nine-model comparison set.** This is the 6NF,
> table-per-attribute leg. The same six logical deliveries run through nine
> warehouses ([Inmon 3NF EDW](../v3_inmon-3nf),
> [Kimball star](../v3_data-marts), [Data Vault 2.0](../v3_datavault),
> [Focal Point](../v3_focal-point), this Anchor, [HOOK](../v3_hook),
> [Unified Star Schema](../v3_unified-star-schema),
> [Activity Schema](../v3_activity-schema), and
> [One Big Table](../v3_one-big-table)), so every difference between them is
> the *model*, never the input. This model takes the narrow,
> one-row-per-attribute originals shared byte-for-byte by Focal Point and
> Anchor. Its archive uses the same narrow layout (`loaded_files` +
> `source_landing_history`, append-only triggers) as the
> [Focal Point](../v3_focal-point) archive. **This README stands on its
> own;** [ANCHOR.md](ANCHOR.md) draws the cross-model comparison.

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
make demo    # fresh archive + schema + a 6-delivery feed sequence, then print the perspectives
make test    # run the suite: 72 assertions, mutation-hardened
make rebuild # throw the constellation away and replay the raw layer to rebuild it
```

`make demo` loads six deliveries that stand in for a few weeks of real feeds, then prints the
business-facing views. The reconstructed customer/product/order tables it produces:

```
### Customers
customer_ref  customer_name  email              signup_date
------------  -------------  -----------------  -----------
C001          Alice Smith    alice@newmail.com  2026-01-05

### Orders
order_ref  status   amount  currency  placed_at         placed_by
---------  -------  ------  --------  ----------------  -----------
O-100      PENDING  29.49   USD       2026-02-01 10:00  Alice Smith
O-101      PENDING  19.5    USD       2026-02-02 11:30
```

Those readable rows are *reconstructed* — none of that shape is stored physically. Each column is a
join into a different attribute table, and the labels (`PENDING`, `USD`) are decoded from knots on the
way out. See [The constellation](#the-constellation-the-four-construct-types) below.

---

## The core idea in one rule

Real feeds don't resend everything every time. A CRM might send a 14-day change window; a product
catalogue might send a full snapshot; an order system might send a 45-day window. If you treat every
delivery as a full snapshot, then "this record wasn't in the file" wrongly reads as "this record was
deleted" — and a customer who simply hasn't changed in 60 days silently disappears.

This warehouse makes the load strategy explicit per feed and enforces one rule:

> **Absence means DELETE only for a FULL delivery.**
> An INCREMENTAL (windowed) delivery never infers a delete from absence. Deletes in an incremental
> world must arrive either as an explicit **tombstone** (`op='DELETE'`) or be found later by a
> **FULL reconciliation**.

The Anchor twist: there is no status column to flip. A delete is recorded as a new assertion in the
entity's **existence knot** — `CU_EST_Customer_Existence` gets a `DELETED` row, dated. Presence is
*data*, versioned like any other attribute, so the "ghost row left in a half-deleted state" failure
mode cannot arise structurally — the read views simply join to the latest existence assertion and keep
only `EXISTS`.

The strategy travels with each delivery (`load_mode` per staged row), and the loader only turns on the
absence-delete branch when the effective mode is `FULL`. Same engine, opposite outcomes — driven only
by the delivery's declared mode.

### The demo delivery sequence

`make demo` runs this exact sequence, and each delivery is there to prove one behaviour:

| #  | Delivery                  | Feed / mode                | What it proves                                                          |
|----|---------------------------|----------------------------|-------------------------------------------------------------------------|
| D0 | `d0_baseline.sql`         | all / FULL                 | initial full load of every feed                                         |
| D1 | `d1_cust_win_day60.sql`   | CRM.CUSTOMER / INCREMENTAL | a 14-day window versions C001's email and **does not** delete absent C002 |
| D2 | `d2_prod_full_v2.sql`     | PIM.PRODUCT / FULL         | absence **does** delete a discontinued SKU (a `DELETED` existence row)   |
| D3 | `d3_cust_tombstone.sql`   | CRM.CUSTOMER / INCREMENTAL | an explicit `op='DELETE'` tombstone deletes C002                         |
| D4 | `d4_cust_recency.sql`     | CRM.CUSTOMER / INCREMENTAL | a repeated attribute resolves to the newest by `extract_ts`             |
| D5 | `d5_cust_yearly_full.sql` | CRM.CUSTOMER / FULL        | a yearly full reconciliation deletes C003, gone at source               |

The test suite drives more of the engine on top of this sequence: it re-sends D1 (a duplicate `file_id`
is skipped by load control), rejects a delivery that reuses a `file_id` with different content, rejects
an unknown status code against the closed knot domain, and loads `fixtures/d7_repoint.sql` to exercise
the historized tie.

---

## The constellation: the four construct types

Anchor decomposes every entity to sixth normal form. The same data the sibling generic-schema demo
holds in **4 tables** is spread here across **24**: 3 anchors, 3 knots, 16 attribute tables, and 2 ties.
That number is the exhibit — Anchor buys per-attribute typing, constraints, and independent history at
the cost of table count.

| Construct                        | Role                     | Holds                                                                 |
|----------------------------------|--------------------------|-----------------------------------------------------------------------|
| **anchor** — `CU_Customer`       | identity only            | one surrogate key + metadata per entity. Nothing else.                |
| **attribute** — `CU_EML_Customer_Email` | one attribute     | a single, properly typed column; *historized* ones add `ChangedAt`    |
| **knot** — `OST_OrderStatus`     | a shared value domain     | an immutable, **closed** set of codes (existence, currency, status)   |
| **tie** — `OD_placed_CU_by`      | a relationship            | connects two anchors; *historized* ties keep latest-per-driving-role  |

Two Anchor idioms are worth noticing in the schema:

- **Even the business key is an attribute.** The anchor row `CU_Customer` is pure identity; the natural
  key `C001` lives in a separate static attribute `CU_REF_Customer_Reference`. Identity and
  identification are distinct facts.
- **Static vs historized is declared per attribute.** A signup date never moves, so
  `CU_SGN_Customer_SignupDate` has no `ChangedAt` and one row per customer. An email changes, so
  `CU_EML_Customer_Email` is keyed `(CU_ID, ChangedAt)` and accumulates versions. **No end dates are
  ever stored** — "current" is computed on the way out as the latest row.

Knots are **closed domains**. `OST_OrderStatus` holds `('P','PENDING')`, `('S','SHIPPED')`, … ; the
loader resolves the raw code `P` to the knot surrogate at load time, and the views read the `PENDING`
label. A delivered code with no matching knot member fails the load loudly rather than inventing a
member. The existence knot `EST_ExistenceStatus` (`EXISTS` / `DELETED`) is how deletes are modeled.

```
                        source deliveries (key/value rows)
                                    │
                     ┌──────────────▼───────────────┐
                     │  source_landing_stage         │  raw delivery lands here
                     │      → source_landing         │  recency-deduped, current per feed
                     └──────────────┬───────────────┘
      meta_* maps  ───drives────►   │  loaders (load_anchors / load_attributes / load_ties)
      (the catalog)                 ▼
             ┌───────────────────────────────────────────────┐
             │  anchors · knots · 16 attribute tables · ties  │  the 6NF constellation (24 tables)
             └──────────────────────┬────────────────────────┘
                                    ▼
             ┌───────────────────────────────────────────────┐
             │  v_customer / v_product / v_order + timelines  │  latest perspectives = the read model
             └───────────────────────────────────────────────┘
```

The loader is not hand-wired per table. Three small metadata maps —
`meta_anchor_map`, `meta_attribute_map`, `meta_tie_map` (seeded in
[`schema/03_anchor.sql`](schema/03_anchor.sql)) — declare which feed keys each anchor, which narrow feed
attribute targets which typed table, whether it is historized, and which knot (if any) resolves its
value. One generic loop reads those maps and retargets itself at each attribute's own table.

---

## The two databases: a disposable warehouse over a durable archive

There are **two** SQLite files, and the split is the most important design decision in the project.

- **`build/anchor.db`** — the derived constellation. Everything you query. **Throwaway.**
- **`archive/anchor_archive.db`** — the raw layer. Every delivery ever accepted, captured *verbatim and
  before it is applied*, append-only, plus a `loaded_files` manifest of what arrived and in what order.
  **Durable.** It lives outside `build/` precisely so that `make clean` and re-initialisation cannot
  touch it.

Because the raw input is never destroyed, the warehouse is disposable:

```bash
make rebuild   # drop build/anchor.db and replay the archive back through the SAME loaders
```

`rebuild` replays every archived delivery, in original ingest order, through the *same* code path that
ingested it ([`scripts/apply_delivery.sh`](scripts/apply_delivery.sh) is shared by ingest and replay —
if replay had its own path, a green rebuild would prove nothing about ingest). This buys two things a
backup never could:

- **Fix a loader bug.** Correct the code and run `make rebuild`. There is no "restore from backup,"
  because the raw input was never overwritten.
- **Change a business rule retroactively.** Order status is stored as the raw code and labelled through
  the `OST` knot at read time. Relabel `'P'` from `PENDING` to `PLACED` with a single `UPDATE` and every
  order — all of history — reads the new label instantly. `make rebuild` then resets it to the schema
  seed, which is the source of truth. (A test exercises exactly this.)

### Rebuild reproduces surrogate keys exactly — and that is load-bearing

Anchor surrogate keys are allocated `MAX(key) + ROW_NUMBER() OVER (ORDER BY business_key)` over the
`*_REF` registry (base 1000), which depends on the order identifiers are first seen. Replaying the
archive reproduces every key *identically*, but only because three orderings are guaranteed and each has
a regression test:

1. deliveries replay in `load_seq` (ingest) order;
2. a delivery's rows are restored to staging in `seq_nbr` (original physical) order, because the
   recency-dedup tiebreak reads the staged rowid;
3. the anchor loader iterates feeds in a fixed order and inserts `*_REF` rows `ORDER BY` business key.

This is why there is **no retention policy**: replaying a *subset* of deliveries would reassign every
key. The archive is a backup only while it is complete, so nothing in the project can delete an archived
row — the append-only triggers in [`schema/02_archive.sql`](schema/02_archive.sql) have no unlock path.

---

## How a delivery flows

A delivery is a plain `.sql` file that inserts key/value rows into `source_landing_stage` (see any file
in [`source/`](source/)). [`scripts/load_feed.sh`](scripts/load_feed.sh) drives one delivery safely,
capturing the raw input *before* applying it:

1. **Stage** the delivery into `source_landing_stage`.
2. **Load control** — look up the delivery's `file_id`. A `file_id` names a delivery's *content* (a
   batch/version id, not a filename — extractors reuse filenames). If it is already `COMPLETE`, skip it.
   If the same `file_id` reappears with *different* rows, reject it loudly rather than let the archive
   stop describing what was actually applied.
3. **Archive** the staged rows verbatim into the append-only `source_landing_history` (idempotent:
   `INSERT OR IGNORE`, which does not fire the delete trigger, so retries are safe).
4. **Apply** via `apply_delivery.sh` → recency-dedup into `source_landing`, then run the three loaders
   (`load_anchors` → `load_attributes` → `load_ties`), each of which branches on the effective
   FULL/INCREMENTAL mode. `load_attributes` also synthesises each entity's existence assertions.
5. **Mark COMPLETE** only after every loader succeeds. A delivery that crashes half-way stays `STARTED`
   and is retried on the next run, never skipped as done; its staged rows are left behind as forensics.

De-duplication happens at three levels: the **file** level (a re-sent `file_id` is skipped), the **row**
level (a repeated attribute keeps the newest by `extract_ts`), and the **version** level — Anchor's
**restatement control**: a historized attribute inserts only when the delivered value differs from the
anchor's latest row, so an unchanged fact writes nothing.

---

## The read model (latest perspectives)

Defined in [`schema/04_views.sql`](schema/04_views.sql), printed by
[`scripts/query.sh`](scripts/query.sh). Because no end dates are stored, "current" is always computed —
the latest row per anchor per historized attribute.

| View                              | What it gives you                                                          |
|-----------------------------------|----------------------------------------------------------------------------|
| `v_customer` / `v_product` / `v_order` | one readable row per entity: joins each attribute table, decodes knots, drops the non-existent |
| `l*` (twelve "latest" views)      | the latest row per anchor for a single historized attribute                |
| `v_customer_email_history`        | one attribute's full timeline, nothing else's — attribute-grain history    |
| `v_existence_history`             | the presence timeline (EXISTS/DELETED) across all three anchors            |
| `v_order_customer_history`        | tie history with `LEAD`-computed end dates and an `iscurrent` flag         |

The twelve hand-written `l*` "latest" views are the honest glimpse of why the official Anchor tooling
exists: in a real model, point-in-time and latest views are *generated*, because writing them by hand
scales with the attribute count.

---

## Make targets

| Target                | Effect                                                                              |
|-----------------------|-------------------------------------------------------------------------------------|
| `make demo`           | fresh archive + schema + the full delivery sequence + printed perspectives          |
| `make rebuild`        | regenerate the constellation by replaying the raw layer                             |
| `make test`           | run the suite (72 assertions)                                                       |
| `make init`           | recreate the derived warehouse from schema (the archive survives)                   |
| `make clean`          | delete `build/` only — **the archive survives**; `make rebuild` restores it         |
| `make clean-archive`  | delete `archive/` — destroys the raw layer and the ability to rebuild (deliberately separate from `clean`) |

---

## Repository layout

```
.
├── Makefile               # the entry point for every workflow
├── ANCHOR.md              # design notes: the same goals as a generic schema, taken the opposite way
├── schema/
│   ├── 01_landing.sql     # narrow key-value landing + the loader metadata maps
│   ├── 02_archive.sql     # the append-only raw layer (separate database)
│   ├── 03_anchor.sql      # the 24-table constellation + knot and map seeds
│   └── 04_views.sql       # latest perspectives, business views, timelines — the read model
├── scripts/
│   ├── lib.sh             # shared helpers; the single choke point for DB access + SQL-injection guards
│   ├── init_db.sh         # (re)create the derived warehouse; preserve the archive
│   ├── load_feed.sh       # ingest ONE delivery safely (stage → archive → apply → complete)
│   ├── apply_delivery.sh  # the one path from staged rows to the warehouse (ingest AND replay)
│   ├── load_anchors.sh    # identities + *_REF business-key registry (deterministic keys)
│   ├── load_attributes.sh # metadata-driven per-attribute loop + existence synthesis
│   ├── load_ties.sh       # ties: historized (latest-per-driving-role) and static
│   ├── rebuild.sh         # replay the archive to regenerate the constellation
│   └── query.sh           # print the perspectives
├── source/                # the demo delivery files (D0–D5)
├── tests/
│   ├── run_tests.sh       # the full suite: delete semantics, restatement control, rebuild, ties
│   └── fixtures/          # extra deliveries used only by tests (d6_tiebreak, d7_repoint)
├── build/                 # generated: the derived constellation (safe to delete)
└── archive/               # generated: the durable raw layer (do NOT delete lightly)
```

---

## Testing

```bash
make test
```

One suite, pure shell + `sqlite3`, 72 assertions, mutation-hardened (each guard is verified by feeding
it the input it is supposed to reject). It covers:

- **Delete semantics under a realistic cadence** — an incremental window does *not* delete an
  absent-but-unchanged record; a FULL snapshot *does* delete on absence; tombstones delete in an
  incremental feed; recency de-duplication; load control (skip a duplicate `file_id`, retry a `STARTED`
  one, reject a `file_id` reused with different content).
- **Anchor-specific behaviour** — attribute-grain history (a changed email versions the email table and
  nothing else); typed columns (`Product_Price` is `REAL`); restatement control (an unchanged value
  writes zero rows); presence-as-data (deletes land in the existence knot, never a `row_st`); closed
  knot domains (an unknown code fails the load and the delivery stays retryable).
- **The raw layer** — the archive captures every delivery verbatim; append-only is absolute (UPDATE and
  DELETE both abort); rebuild reproduces the constellation *exactly*, anchor surrogate keys included; a
  relabelled knot re-derives from the untouched raw values.
- **The historized tie** — re-pointing an order from one customer to another appends a new pairing,
  supersedes the old one by `ChangedAt`, and end-dates it via `LEAD` without ever updating a row.

All assertions pass with no external setup.

---

## What the constellation gives up

The comparison is the point of the project, so the costs are stated plainly:

- **Table count grows linearly with the model.** 16 attribute tables for ten mapped attributes plus
  presence; a real domain multiplies this fast — which is exactly why the official Anchor tooling is a
  code generator. The hand-written twelve "latest" views in `04_views.sql` are the honest glimpse of it.
- **Every read is a join fan-out.** `v_customer` touches six tables. Anchor's production answer is
  generated point-in-time views and engine-level table elimination, neither of which SQLite provides.
- **Evolution is DDL after all** — additive-only and non-destructive, but a new attribute is still a
  migration artifact (a new `CREATE TABLE`), where a generic metadata-driven schema absorbs it as a row.

In exchange you get per-attribute typing and constraints, independent history per attribute, closed
value domains enforced by the schema, and a re-point handled natively by a historized tie.

### Deviations from canonical Anchor, documented

For join legibility and to run on stock SQLite, a few conventions differ from the reference model:
column names drop the mnemonic prefix (`CU_NAM_CU_ID` → `CU_ID`); `OST` is a "described" knot carrying
both code and label so the retroactive-relabel test works; the order mnemonic is `OD` rather than `OR`
(bare `OR` is a SQL keyword); `Metadata_LDTS` stands in for Anchor's metadata construct; and there is no
positor/reliability machinery (concurrent-reliance modeling is out of scope).

---

## Going deeper

- **[ANCHOR.md](ANCHOR.md)** — the design notes: how a 6NF constellation reaches the same goals as a
  generic metadata-driven schema by the opposite physical route, where each borrowed loading mechanism
  (mode-aware deletes, tombstones, restatement control, ordered replay) lands on a native Anchor
  construct, and what the model gives up in exchange.
