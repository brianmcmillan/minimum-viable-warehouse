# Unified Star Schema: one bridge, no traps

A small, fully working Unified Star Schema (USS) warehouse, the
presentation model Francesco Puppini set out with Bill Inmon in *The
Unified Star Schema*, built from nothing but **`sqlite3`, `bash`, and
`make`**. No Python, no dbt, no BI tool, no server. Clone it, run
`make demo`, and you have a warehouse where any column from any table can
be dropped into one query and still add up correctly, sitting on an
insert-only history core that handles deletes safely and rebuilds exactly
from a durable raw layer.

The USS answers a question the other models in this repo mostly leave to
the analyst: *what happens when someone joins two tables at different
grains and sums?*

- **One table in the middle: the bridge.** `_bridge` is a `UNION ALL` of
  *stages*, one per table. Each stage row carries its own table's key plus
  every key it reaches through many-to-one paths.
- **Tables lose their foreign keys.** `customer`, `product`, `orders`, and
  `order_line` each keep their columns and get one key, `_key_<table>`.
  Every join goes bridge → table, `LEFT`, on one key.
- **Measures live on their own stage.** The order amount is on the
  `Orders` rows and `NULL` on the `Order line` rows, so an order with two
  lines can't be counted twice. That's the **fan trap**, gone by
  construction.
- **Every table has a stage.** A customer with no orders still has a
  `Customer` row on the bridge, so it still shows up. That's the
  **chasm trap**, gone by construction.

> **Part of a nine-model comparison set.** This is the presentation-layer
> leg. The same six logical deliveries run through nine warehouses
> ([Inmon 3NF EDW](../v3_inmon-3nf), [Kimball star](../v3_data-marts),
> [Data Vault 2.0](../v3_datavault), [Focal Point](../v3_focal-point),
> [Anchor](../v3_anchor), [HOOK](../v3_hook), this Unified Star Schema,
> [Activity Schema](../v3_activity-schema), and
> [One Big Table](../v3_one-big-table)), so every difference between them is
> the *model*, never the input. This model takes the wide,
> one-row-per-record restatement shared byte-for-byte by Inmon, Kimball,
> Data Vault, HOOK, USS, Activity Schema and OBT. Its archive uses the same
> layout (`loaded_files` + per-feed `hist_*` tables, append-only triggers)
> as the Inmon, Kimball, HOOK, Activity Schema and OBT archives. **This
> README stands on its own;** [USS.md](USS.md) draws the cross-model
> comparison.

---

## Requirements

| Tool      | Developed against       | Notes                                   |
|-----------|-------------------------|-----------------------------------------|
| `bash`    | 5.x (also runs on 3.2)  | the built-in macOS bash works           |
| `sqlite3` | 3.54                    | any modern SQLite with window functions |
| `make`    | 3.81+ (GNU Make)        | the stock macOS binary works            |

Everything runs against local files in this directory; nothing reaches the
network.

---

## Quick start

```bash
make demo          # fresh archive + schema + the full 6-delivery sequence, then print the warehouse
make refresh       # re-derive the USS layer from the core (no reload)
make rebuild       # delete core + USS; replay the raw layer to rebuild both
make test          # 113 assertions: delete semantics, bridge shape, traps, as-of, exact rebuild
make clean         # delete build/ only — the archive SURVIVES
make clean-archive # delete archive/ — destroys the raw layer, and the ability to rebuild
```

After `make demo`, this is the whole bridge:

```
### _bridge
  stage     _key_customer  _key_orders  _key_order_line  _key_product  order_amount  line_count
----------  -------------  -----------  ---------------  ------------  ------------  ----------
Customer    C001
Product                                                  SKU-1
Product                                                  SKU-2
Orders      C001           O-100                                              29.49
Orders      C002           O-101                                               19.5
Order line  C001           O-100        O-100|SKU-1      SKU-1                                1
Order line  C001           O-100        O-100|SKU-2      SKU-2                                1
Order line  C002           O-101        O-101|SKU-2      SKU-2                                1
```

Read it row by row. An order line carries its *customer's* key even though
`order_line` has no customer column: the refresh walked line → order →
customer and wrote the result down. The amount appears once per order.
And here is why that matters:

```
### Order amount, three ways
naive_join_total  bridge_total  true_total
----------------  ------------  ----------
           78.48         48.99       48.99
```

`naive_join_total` is what anyone gets by joining orders to their lines and
summing `amount`: O-100 has two lines, so its 29.49 counts twice. The bridge
sums the same column from the `Orders` stage and gets the right number. No
`DISTINCT`, no subquery, no knowing which grain is which.

---

## The core idea, in one rule

The USS is a presentation layer. It doesn't say how to load or keep
history, so this leg puts it on top of an **insert-only core** and enforces
the rule every model in the set shares:

> **Absence means DELETE only for a FULL delivery.**
> An INCREMENTAL delivery never infers a delete from absence. Deletes arrive
> as an explicit **tombstone** (`op='DELETE'`) or are found later by a
> **FULL reconciliation**.

The core records every change and every delete as a row. The USS is then
fully re-derived from the core's current state after each delivery.

| event | core (insert-only) | USS (derived) |
|---|---|---|
| attribute change | new row, `change_type='UPDATE'` | table row re-derived |
| delete detected | new row, `change_type='DELETE'`, `delete_basis` = `TOMBSTONE` / `FULL_ABSENCE` | member leaves its table and its stage |
| unchanged re-delivery | `diff_str` matches — writes nothing | refresh produces an identical bridge |
| re-pointed relationship | new order row with the new `customer_ref` | the order's **and its lines'** bridge rows move to the new customer |
| business rule (`P → PENDING`) | raw `'P'` stored | decoded at refresh; `make refresh` applies a rule change |

### The demo delivery sequence

| #  | Delivery                  | Feed / mode                | What it proves                                                                    |
|----|---------------------------|----------------------------|-----------------------------------------------------------------------------------|
| D0 | `d0_baseline.sql`         | all / FULL                 | initial full load; the bridge's four stages                                       |
| D1 | `d1_cust_win_day60.sql`   | CRM.CUSTOMER / INCREMENTAL | a 14-day window updates C001 and **does not** delete stale, absent C002           |
| D2 | `d2_prod_full_v2.sql`     | PIM.PRODUCT / FULL         | absence **does** delete a discontinued SKU                                        |
| D3 | `d3_cust_tombstone.sql`   | CRM.CUSTOMER / INCREMENTAL | a tombstone deletes C002; O-101's amount still counts, with no name               |
| D4 | `d4_cust_recency.sql`     | CRM.CUSTOMER / INCREMENTAL | adds C003, newest by `extract_dt`; order-less C003 still appears (no chasm trap)  |
| —  | re-send D1                | (same `file_id`)           | load control skips a duplicate delivery (exercised by `make test`)                |
| D5 | `d5_cust_yearly_full.sql` | CRM.CUSTOMER / FULL        | a yearly full reconciliation deletes C003, gone at source                         |

---

## How the warehouse is shaped

```
                     source deliveries (op / load_mode rows)
                                   │
                    ┌──────────────▼───────────────┐
                    │  stg_*_l1        (stage L1)   │  one wide table per feed
                    │      → v_stg_*_l2 (views)     │  recency-dedup + diff_str
                    └──────────────┬───────────────┘
                                   │  load_core.sh (one generic engine,
                                   │  driven by the core_table registry)
                                   ▼
                    ┌──────────────────────────────┐
                    │  core_customer  core_product  │  insert-only history,
                    │  core_order  core_order_line  │  natural keys, deltas only
                    └──────────────┬───────────────┘
                                   │  refresh_uss.sh (full re-derive,
                                   │  one transaction)
                                   ▼
          ┌──────────────────────────────────────────────────────┐
          │            customer      product                     │
          │                  ╲        ╱                          │  the star:
          │                   _bridge                            │  every join is
          │                  ╱        ╲                          │  bridge → table
          │            orders        order_line                  │
          └──────────────────────────┬───────────────────────────┘
                                     ▼
          v_customer / v_product / v_order / v_sales_by_customer /
          v_sales_by_product / v_fan_trap        (+ history views over the core)
```

### The USS tables

| Table        | Key               | Holds                                                         |
|--------------|-------------------|---------------------------------------------------------------|
| `customer`   | `_key_customer`   | current, non-deleted customers                                |
| `product`    | `_key_product`    | current, non-deleted products                                 |
| `orders`     | `_key_orders`     | current orders; `status` decoded, `status_code` raw; **no `customer_ref`** |
| `order_line` | `_key_order_line` | current `order_ref|sku` pairs                                 |
| `_bridge`    | (none)            | one row per table row, tagged by `stage`                      |

### The bridge stages

| Stage        | Keys it carries                                                    | Measure          |
|--------------|--------------------------------------------------------------------|------------------|
| `Customer`   | `_key_customer`                                                    | —                |
| `Product`    | `_key_product`                                                     | —                |
| `Orders`     | `_key_orders`, `_key_customer`                                     | `order_amount`   |
| `Order line` | `_key_order_line`, `_key_orders`, `_key_product`, `_key_customer` (via the order) | `line_count` |

**Why `O-101` still points at C002 after C002 is deleted.** The bridge
records what the order says, not what still exists. So O-101's 19.5 stays
in every total, and the `LEFT JOIN` to `customer` simply finds no name.
That matches every sibling's `placed_by` being blank, and keeps the
revenue honest.

---

## Two tiers, two kinds of mutability

- **The core never mutates.** Triggers refuse `UPDATE` and `DELETE`. It
  holds every version and every delete, with the delivery that wrote it.
  The core loader is the same registry-driven engine as the HOOK leg's
  frame loader, pointed at natural-key tables.
- **The USS is derived and disposable.** `refresh_uss.sh` deletes and
  re-inserts it in one transaction after every delivery. Nothing is lost,
  because everything in it can be recomputed from the core.

That split explains the decode behaviour. Change `ref_order_status` and
`v_order` keeps showing the old label: the USS is materialised. Run
`make refresh` (or `scripts/refresh_uss.sh`) and the new label appears
everywhere, without reloading a single delivery. The history views read the
core directly and pick it up immediately.

Point-in-time lives in the core too. `v_order_as_recorded` resolves each
order row against the customer row that was latest when it loaded, so the
deleted C002 still answers *Bob Jones* for the order as originally recorded.

---

## The two databases: disposable warehouse over a durable raw layer

- **`build/uss.db`** — stage, core, USS, views. **Throwaway.**
- **`archive/uss_archive.db`** — every delivery ever accepted, captured
  *verbatim and before it is applied*, append-only, plus a `loaded_files`
  manifest. **Durable.** `make clean` never touches it.

`make rebuild` replays every archived delivery, in original order, through
the same `apply_delivery.sh` path that ingested it (core load, then USS
refresh). The suite asserts that the rebuilt core *and* bridge are
identical to what ingest produced.

### How a delivery flows

1. **Stage** the delivery into `stg_*_l1`; record `batch_ts` and `file_id`
   in `load_params`.
2. **Load control** — skip a `file_id` already `COMPLETE`; reject a reused
   `file_id` with a different row count.
3. **Archive** the staged rows verbatim (`INSERT OR IGNORE`, safe to retry).
4. **Apply** via `apply_delivery.sh` → `load_core.sh` → `refresh_uss.sh`.
5. **Mark COMPLETE**, then clear the stage. A crash leaves the delivery
   `STARTED` with its staged rows in place as forensics.

---

## The read model (views)

| View                    | What it gives you                                                       |
|-------------------------|-------------------------------------------------------------------------|
| `v_customer` / `v_product` | current members — column-for-column with the sibling demos          |
| `v_order`               | `FROM _bridge` (Orders stage) → `orders`, `customer`; `placed_by` by bridge key |
| `v_sales_by_customer`   | orders, order amount, and line count per customer in one query, all correct |
| `v_sales_by_product`    | orders and line count per product; no invented allocation of order amounts |
| `v_fan_trap`            | the naive join total next to the bridge total and the true total        |
| `v_order_as_recorded`   | point-in-time, from the core                                            |
| `v_customer_history`    | every core customer row                                                 |

`v_sales_by_product` deliberately has no amount column. The amount belongs
to the order, and the bridge won't spread it across products for you. A
split has to be a business rule someone writes down.

---

## Make targets

| Target               | Effect                                                                   |
|----------------------|--------------------------------------------------------------------------|
| `make demo`          | fresh archive + schema + the full delivery sequence + printed warehouse  |
| `make refresh`       | re-derive the USS from the core (picks up reference-data changes)        |
| `make rebuild`       | regenerate core + USS by replaying the raw layer                         |
| `make test`          | run the test suite (113 assertions)                                      |
| `make init`          | recreate the database from schema (the archive survives)                 |
| `make clean`         | delete `build/` only — **the archive survives**                          |
| `make clean-archive` | delete `archive/` — destroys the raw layer and the ability to rebuild    |

---

## Repository layout

```
.
├── Makefile
├── USS.md                   # design notes: the USS vs the sibling models
├── schema/
│   ├── 01_stage.sql         # stage L1 tables (shared shape) + L2 dedup / diff_str views
│   ├── 02_archive.sql       # raw layer: append-only wide history + manifest + triggers
│   ├── 03_core.sql          # core_table registry, insert-only core, latest views, ref data
│   └── 04_uss.sql           # USS tables, _bridge, business / trap / history views
├── scripts/
│   ├── lib.sh               # shared helpers; the single DB choke point
│   ├── init_db.sh           # (re)create the database; preserve the archive
│   ├── load_feed.sh         # ingest ONE delivery (stage → archive → apply → complete)
│   ├── apply_delivery.sh    # the one path for ingest AND replay: core, then USS
│   ├── load_core.sh         # the generic, registry-driven core loader
│   ├── refresh_uss.sh       # full re-derive of the USS tables and the bridge
│   ├── rebuild.sh           # ordered replay of the archive
│   └── query.sh             # print the warehouse
├── source/                  # D0–D5, byte-identical with ../v3_datavault, ../v3_inmon-3nf, ../v3_hook
├── tests/
│   ├── run_tests.sh         # 113 assertions
│   └── fixtures/d6_repoint.sql   # O-101 re-pointed to C001 (data row identical to the siblings')
├── build/                   # generated (safe to delete)
└── archive/                 # generated: the durable raw layer
```

---

## Testing

```bash
make test
```

**113 assertions**, pure shell + `sqlite3`, covering:

- **Delete semantics** — the stale-window trap, FULL-absence deletes,
  tombstones, recency dedup, load control, and zero-churn idempotence (the
  refreshed bridge is identical, too).
- **The USS shape** — each table has only its own key; `orders` has no
  customer column; the bridge carries every key; after every delivery, each
  stage has exactly one row per table row.
- **The traps** — measures only on their own stage; the naive join double
  counts and the bridge doesn't; order-less customers and never-ordered
  products still appear.
- **Transitive keys** — order lines carry their order's customer, and follow
  it when the order is re-pointed.
- **Tiers** — the core is insert-only; a decode change waits for a refresh,
  not a reload; `make clean` + replay reproduces the core and the bridge
  exactly.

Mutation-checked: removing the FULL guard, the NOCHANGE guard, or the
tombstone branch; reversing the dedup tiebreak or the replay order; putting
the order amount on line rows; dropping the transitive customer key;
dropping the Customer stage; keeping deleted members in the USS; or leaving
`customer_ref` out of the order diff each turn the suite red.

---

## What the USS gives up

- **It isn't a history model.** The bridge is current state. History and
  point-in-time come from whatever sits underneath — here, the core.
- **The bridge grows with every table.** Each new table adds a stage and a
  key column. Rows multiply with the number of tables, not the number of
  facts.
- **Measures at one grain stay at that grain.** Order amounts don't split
  by product. That's correct, and it's also a question the business still
  has to answer itself.
- **It's materialised.** Rule changes need a refresh, and the refresh here
  is a full rebuild of the layer. Cheap at this size, a design problem at
  scale.
- **Loops need care.** When two paths connect the same tables (say, an
  order's billing customer and its shipping customer), the USS needs
  separate keys or aliased tables per path. This corpus has no loops, so the
  demo doesn't exercise that.

---

## Going deeper

- **[USS.md](USS.md)** — what the USS is, where this implementation
  follows it and where the shared discipline fills gaps, and how it compares
  with the sibling models.
- **Sibling demos** — [`../v3_data-marts`](../v3_data-marts) is the
  classic star this generalises; [`../v3_hook`](../v3_hook) shares the
  generic loader; [`../v3_one-big-table`](../v3_one-big-table) is the other
  "one table to query" answer. The [top-level README](../README.md) sets out
  the full set.
