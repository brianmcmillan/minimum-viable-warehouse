# Metrics mart: resources, metrics and samples in 3NF

A small, fully working metrics mart built from nothing but **`sqlite3`,
`bash`, and `make`**. No Python, no dbt, no server, no packages to install.
The core tables follow the ER diagrams in
[`../docs/metrics-mart-notes.pdf`](../docs/metrics-mart-notes.pdf): an
Inmon-style 3NF model with its codes snowflaked out to their own tables.
Clone it, run `make demo`, and you have a mart where every thing is a
resource, every number is a metric sample, deletes are handled safely under
realistic feed cadences, and the whole thing can be thrown away and rebuilt
from a durable raw layer.

The mart's bet is that a warehouse of measurements needs two kinds of table
and no more. One kind says **what things exist** (resources, their types,
their groups). The other says **what was measured on them, and when**.

- **One resource table for every type.** `RES` holds customers, products and
  orders alike, told apart by `res_type`. A resource has a name, a status and
  one parent.
- **A metric is a row, not a column.** `METRIC` lists what can be measured.
  `METRIC_SAMPLE` holds one observation per resource, metric, provider and
  moment. Price and amount are not columns anywhere.
- **Identity goes through an alias.** A provider names a resource however it
  likes. `RES_ALIAS` turns that name into a `res_id`, and every metric and
  every parent reference is resolved through it.
- **Resources are current state.** The diagram gives `RES` no validity
  dates. A changed email is an `UPDATE` in place and a delete is
  `res_status = 0`. History of *measurements* is the samples. History of
  *descriptors* is only in the archive.
- **Aggregates are derived.** Daily summaries, weekly rollups and group
  weeks are recomputed after every delivery.

> **Part of a ten-model comparison set.** This is the measurement leg. The
> same six logical deliveries run through ten warehouses
> ([Inmon 3NF EDW](../v3_inmon-3nf), [Kimball star](../v3_data-marts),
> [Data Vault 2.0](../v3_datavault), [Focal Point](../v3_focal-point),
> [Anchor](../v3_anchor), [HOOK](../v3_hook),
> [Unified Star Schema](../v3_unified-star-schema),
> [Activity Schema](../v3_activity-schema), this metrics mart, and
> [One Big Table](../v3_one-big-table)), so every difference between them is
> the *model*, never the input. Its deliveries are the wide,
> one-row-per-record files every model shares byte-for-byte, archived in the
> shared layout (`loaded_files` + per-feed `hist_*` tables, append-only
> triggers). A second staging step, the same one
> [Focal Point](../v3_focal-point) and [Anchor](../v3_anchor) use, unpivots
> them into narrow key/value rows. The target is different: a 3NF model with
> real columns and real foreign keys. **This README stands on its own;**
> [METRICSMART.md](METRICSMART.md) reviews the ER diagrams and draws the
> cross-model comparison.

---

## Requirements

| Tool      | Developed against       | Notes                                                    |
|-----------|-------------------------|----------------------------------------------------------|
| `bash`    | 5.x (also runs on 3.2)  | the built-in macOS bash works                            |
| `sqlite3` | 3.35+                   | window functions, `UPDATE ... FROM`, upsert              |
| `make`    | 3.81+ (GNU Make)        | the stock macOS binary works                             |

Everything runs against local files in this directory; nothing reaches the
network.

---

## Quick start

```bash
make demo          # fresh archive + schema + the full 6-delivery sequence, then print the mart
make rebuild       # delete the mart; replay the raw layer to rebuild it
make test          # 237 assertions (36 core, 201 model): delete semantics, samples, aggregates, exact rebuild
make clean         # delete build/ only — the archive SURVIVES
make clean-archive # delete archive/ — destroys the raw layer, and the ability to rebuild
```

`make demo` loads the six shared deliveries standing in for a few weeks of
real feeds and prints the mart. One table holds every resource:

```
### RES
res_id  res_type  res_code  res_name     status   parent
------  --------  --------  -----------  -------  -------------
1       CUSTOMER  C001      Alice Smith  LIVE
2       CUSTOMER  C002      Bob Jones    DELETED
3       ORDER     O-100     O-100        LIVE     CUSTOMER:C001
4       ORDER     O-101     O-101        LIVE     CUSTOMER:C002
5       PRODUCT   SKU-1     Widget       LIVE
6       PRODUCT   SKU-2     Gadget       LIVE
7       PRODUCT   SKU-3     Gizmo        DELETED
8       CUSTOMER  C003      Carol Diaz   DELETED
```

And one table holds every number:

```
### METRIC_SAMPLE (history lives here, including deleted resources)
res_type  res_code  metric_code  provider_name  sample_utc_ts        value
--------  --------  -----------  -------------  -------------------  -----
ORDER     O-100     amount       OMS            2026-02-05 00:00:00  29.49
ORDER     O-101     amount       OMS            2026-02-05 00:00:00  19.5
PRODUCT   SKU-1     price        PIM            2026-02-05 00:00:00  9.99
PRODUCT   SKU-1     price        PIM            2026-03-02 00:00:00  8.99
PRODUCT   SKU-2     price        PIM            2026-02-05 00:00:00  19.5
PRODUCT   SKU-2     price        PIM            2026-03-02 00:00:00  19.5
PRODUCT   SKU-3     price        PIM            2026-02-05 00:00:00  5.0
```

SKU-1's price history is two samples. SKU-2's unchanged price is also two
samples, because PIM observed it twice. SKU-3 was discontinued and keeps its
sample. The business views read the newest sample as the current value:

```
### Products
sku    product_name  price  currency
-----  ------------  -----  --------
SKU-1  Widget        8.99   USD
SKU-2  Gadget        19.5   USD
```

---

## The core idea, in one rule

Real feeds don't resend everything every time. A CRM sends a 14-day change
window; a product catalogue sends a full snapshot. Treat every delivery as a
full snapshot and "this record wasn't in the file" wrongly reads as "this
record was deleted."

This demo makes the load strategy explicit **per delivery** and enforces one
rule, shared with every sibling model:

> **Absence means DELETE only for a FULL delivery.**
> An INCREMENTAL delivery never infers a delete from absence. Deletes arrive
> as an explicit **tombstone** (`op='DELETE'`) or are found later by a
> **FULL reconciliation**.

The diagrams give the staging tables a `batch_no`, a `sequence_no` and a
`load_oper`. That covers ordering and explicit deletes. Nothing in them says
whether a batch is a full snapshot or a change window, so the shared rule
fills that gap. The router applies it while the delivery's mode is still
known and hands the loaders a plain `load_oper = 'D'`.

| event | metrics mart (this demo) |
|---|---|
| descriptor change | `UPDATE` in place on `RES` or its subtype table; changed rows only |
| numeric change | a new `METRIC_SAMPLE` row at the observation time |
| delete detected | `res_status = 0`; the row and its samples stay |
| unchanged re-delivery | descriptors write nothing; a numeric value observed again is a new sample |
| re-pointed relationship | `parent_res` overwritten in place |
| business rule (`P → PENDING`) | raw `'P'` in `RES_ORDER`; decoded **on read** by joining `ORDER_STATUS` |
| row mutation | yes: `RES` and its subtypes update in place; samples overwrite only on a correction |

### The demo delivery sequence

| #  | Delivery                  | Feed / mode                | What it proves                                                                |
|----|---------------------------|----------------------------|-------------------------------------------------------------------------------|
| D0 | `d0_baseline.sql`         | all / FULL                 | initial full load of every feed                                               |
| D1 | `d1_cust_win_day60.sql`   | CRM.CUSTOMER / INCREMENTAL | a 14-day window updates C001 and **does not** delete stale, absent C002       |
| D2 | `d2_prod_full_v2.sql`     | PIM.PRODUCT / FULL         | absence **does** delete a discontinued SKU                                    |
| D3 | `d3_cust_tombstone.sql`   | CRM.CUSTOMER / INCREMENTAL | an explicit `op='DELETE'` tombstone deletes C002 in an incremental feed       |
| D4 | `d4_cust_recency.sql`     | CRM.CUSTOMER / INCREMENTAL | adds C003; a repeated key resolves to the newest by `extract_ts`, not `MAX()` |
| —  | re-send D1                | (same `file_id`)           | load control skips a duplicate delivery (exercised by `make test`)            |
| D5 | `d5_cust_yearly_full.sql` | CRM.CUSTOMER / FULL        | a yearly full reconciliation deletes C003, gone at source                     |

D0–D5 in `source/` are the wide files, byte-identical in all ten models.

---

## How the shared corpus maps onto the mart

The mart was drawn for resources that get measured. The shared corpus is
customers, products and orders. The mapping is a few rows of metadata.

| in the narrow row (after `stage_narrow.sh`) | in the mart |
|---|---|
| `source_system` (CRM, PIM, OMS) | `PROVIDER` |
| `source_entity` (CUSTOMER, PRODUCT, ORDER) | `RES_TYPE` |
| `business_key` (`C001`) | `RES.res_code`, and a `RES_ALIAS` row that resolves to it |
| `full_name`, `prod_name` | `RES.res_name` |
| `price`, `amount` (numeric) | `METRIC` rows; each delivered value is a `METRIC_SAMPLE` |
| an order's `customer_ref` | `RES.parent_res`, allowed by a `RES_TYPE_REL` row |
| an order line (`O-100~SKU-1`) | a `RES_RESGRP` row: product SKU-1 is a member of group `/ORDER/O-100` |
| `email_addr`, `signup_date`, `currency`, `status`, `placed_at` | subtype tables `RES_CUSTOMER`, `RES_PRODUCT`, `RES_ORDER` (not in the diagrams) |
| `op='DELETE'`, or absence under FULL | `RES_STG.load_oper = 'D'`, then `RES.res_status = 0` |

An order is a resource, because it has a parent and an amount. Its basket is
a group, because it has members. That is what gives the group aggregate
something to say: the weekly list prices of an order's members add up to its
basket at list price.

```
### Group weeks: each order's basket at list price
group_path    week_start  members  basket_at_list_price
------------  ----------  -------  --------------------
/ORDER/O-100  2026-02-02  2        29.49
/ORDER/O-100  2026-03-02  2        28.49
/ORDER/O-101  2026-02-02  1        19.5
/ORDER/O-101  2026-03-02  1        19.5
```

O-100's amount is 29.49 and stays 29.49. Its basket at list price drops to
28.49 the week SKU-1 is repriced.

---

## How the mart is shaped

### Tables from the diagrams

| group | tables |
|---|---|
| staging | `METRIC_STG`, `METRIC_STG2`, `RES_STG`, `RES_ALIAS_STG`, `RES_RESGRP_STG` |
| resource | `RES`, `RES_TYPE`, `RES_TYPE_REL`, `RES_ALIAS`, `RES_GRP`, `RES_RESGRP` |
| metrics | `METRIC`, `VALUE_TYPE`, `PROVIDER`, `METRIC_SAMPLE`, `METRIC_SUMMARY` |
| aggregations | `METRIC_WEEKLY`, `GRP_METRIC_WEEKLY` |
| calendar | `CALNDR`, the day table (the event tables are not built; see below) |

Column names and declared types are the diagrams'. Foreign keys are real and
switched on for every connection.

### Not built

`TIME_ZONE`, `TZ_CODE`, `COUNTRY` and `RAW_RES_TYPE` are extensions to the
model and are left out. Every `*_tz_code` column is `'UTC'`, and local timestamps equal UTC
ones. `site_id`, `support_ctr_id` and `client_id` point at tables the
diagrams don't show; they are plain nullable columns here.

The calendar-event tables (`CALNDR_EVENT`, `CALNDR_EVENT_STG`, `CAL_EVT_TYPE`)
were built and then removed to keep the ten demos like for like: no sibling
model stores planned events. The tag `metrics-mart-with-calendar` has them,
with the `CAL_EVT_GRP` table added for them, their loader, views and tests.
`CALNDR`, one row per day for 2026 and 2027, stays as a standard day table,
like `dim_date` in the Kimball demo, and the weekly rollups take their
Monday from it.

### Added

- **Unique keys** on `RES (res_type, res_code)`, `METRIC.metric_code`,
  `PROVIDER.provider_name` and `RES_GRP.group_path`. The diagrams show only
  the surrogate primary keys.
- **Three subtype tables** (`RES_CUSTOMER`, `RES_PRODUCT`, `RES_ORDER`) and
  **two code tables** (`ORDER_STATUS`, `CURRENCY`). `RES` has a name, a short
  name and a description. The corpus also carries an email, a signup date, a
  currency, a status and a placed-at time, and in a 3NF model those belong in
  subtype tables keyed on `res_id`.
- **Two readings of unexplained columns.** `srcd_ts` is taken as "when the
  mart last recorded a change to this row" (the batch timestamp). `srcd_d2k`
  on `METRIC_SAMPLE` is taken as that same date in whole days since
  2000-01-01. Both are assumptions.

### Routing metadata

Two small tables decide where each narrow row goes. No loader names a feed
or an attribute.

| table | one row per | says |
|---|---|---|
| `meta_feed_map` | feed | whether its keys are resources (and of which type) or group memberships |
| `meta_attribute_map` | attribute | `KEY`, `RES_COL`, `SUBTYPE` (table and column), `PARENT` (parent type) or `METRIC` (metric code) |

This is the Focal and Anchor idea pointed at a 3NF target, and it works to a
point. A new **metric** is two rows (one in `METRIC`, one in the map) with no
DDL and no loader change; the suite proves it. A new **descriptive
attribute** still needs a column first, because this is 3NF. Only its
routing is metadata.

---

## The loaders

`scripts/apply_delivery.sh` is the one path from staged rows to the mart,
used by both ingest and replay.

1. **Landing.** Replace each delivered feed's rows in `source_landing`,
   keeping the newest per key and attribute by `extract_ts`, ties broken by
   file order.
2. **Route** (`route_stage.sh`). Fill `RES_STG`, `RES_ALIAS_STG`,
   `METRIC_STG` and `RES_RESGRP_STG`. Apply the delete rule.
3. **Resources** (`load_res.sh`). Create providers and new resources,
   resolve parents through `RES_ALIAS`, update changed descriptors, restore
   or delete by `load_oper`, then set subtype columns one generated statement
   per mapped attribute.
4. **Groups** (`load_groups.sh`). Create groups from their paths, keep the
   type groups current and reconcile memberships.
5. **Metrics** (`load_metrics.sh`). Resolve `METRIC_STG` into `METRIC_STG2`
   and upsert `METRIC_SAMPLE`. A sample dated outside `CALNDR` fails the
   load.
6. **Aggregates** (`refresh_aggregates.sh`). Recompute daily summaries,
   weeks and group weeks; touch only the rows whose numbers changed.

Each step is one transaction and each is safe to run again. Each also runs
through `sql_tx` (in `lib.sh`), which copies the mart file first and puts the
copy back if the step fails. Builds of the `sqlite3` shell differ in what
they do after an error inside a transaction, so the copy is what makes a
failed step leave no trace on every one of them.

Three details matter more than the rest.

**Measurements skip the landing dedup.** The landing keeps the newest row
per key and attribute. That is right for an email and wrong for a price: two
prices at two times are two observations. `METRIC_STG` is filled from the
stage with the time in the dedup key, so only a true duplicate collapses.

**Only the feeds that just arrived are processed.** `source_landing` keeps
the last delivery of every feed. A CRM window must not re-run the product
snapshot from last month, so every loader reads the landing through a filter
on the feeds in the current delivery.

**Guards run before commit.** `RES_TYPE_REL` says which parent and child
types may pair, and no key in the diagram enforces it. `RES_GRP` stores one
hierarchy three ways (parent, level, path), and nothing keeps them in step.
Both are checked by a view that must be empty, through a `load_guard` table
whose `CHECK` fails the transaction.

---

## The two databases: a disposable mart over a durable raw layer

- **`build/metrics.db`** — landing, staging, the mart, views. **Throwaway.**
- **`archive/metrics_archive.db`** — every delivery ever accepted, captured
  *verbatim and before it is applied*, append-only, plus a `loaded_files`
  manifest. **Durable.** `make clean` never touches it. Its layout is the
  shared wide one (`hist_*` per source extract), the same in all ten models.

The archive matters more here than in most of the siblings. `RES` keeps no
history, so the raw layer is the only place an earlier email, an earlier
parent or a corrected sample value can still be found.

`make rebuild` replays every completed delivery in its original order
through the *same* `stage_narrow.sh` and `apply_delivery.sh` path that
ingested it. The suite
asserts the rebuilt mart is identical, down to each `res_id`, `provider_id`,
`res_grp_id` and `srcd_ts`.

### How a delivery flows

1. **Stage** the delivery into the wide `stg_*_l1` tables.
2. **Load control** — compare the staged file with what the archive holds for
   its `file_id`: the row count must match the manifest, and once rows are
   archived every row must match exactly, order included. Any mismatch is
   rejected loudly, whether the id is `COMPLETE` or a crashed `STARTED` one.
   Only then is a `COMPLETE` id skipped and a `STARTED` one retried.
3. **Archive** the staged wide rows verbatim into the `hist_*` tables
   (`INSERT OR IGNORE`, safe to retry). The archive's `load_seq` becomes the
   mart's `batch_no`.
4. **Stage narrow** — `scripts/stage_narrow.sh` (the same script Focal and
   Anchor use) unpivots each wide row into one key/value row per attribute
   in `source_landing_stage`: price/amount to `value_num`, dates to
   `value_ts`, the rest to `value_str`; an empty column as SQL `NULL`; one
   `_tombstone` row for a `DELETE`; in a fixed order. `route_stage.sh`
   reads measurements from here, before the landing dedups them.
5. **Apply** via `apply_delivery.sh`.
6. **Mark COMPLETE**, then clear both stages. A crash leaves the delivery
   `STARTED` with its staged rows in place as forensics.

### A native narrow archive is a supported option

If your extracts really are narrow (an EAV export, or a change stream that sends one attribute at a
time), you can stage them straight into `source_landing_stage`, archive that shape (a
`source_landing_history`-style table keyed on file and row), and skip `stage_narrow.sh`. The loaders
don't change. Two costs come with it:

- **It makes switching harder, in both directions.** The models that take wide extracts can't
  replay a narrow archive, and the mart can't replay theirs, without a conversion step. The
  delivery files also stop being shared, so a cross-model comparison is no longer like for like.
- **It needs its own content-checked load-control guard.** The shared guard compares the wide
  stage with the `hist_*` tables only. A narrow archive must compare `source_landing_stage`
  with its own history table, every row and in order, to keep the same rule: a reused
  `file_id` whose rows differ is rejected, whether the delivery completed or crashed.

For this mart there is a third consideration, in its favour: a narrow archive keeps "a new metric is
a row" true all the way down, because a metric a source starts sending is just a new
`attribute_name`. With the wide raw layer it needs a new column (see "What the metrics mart gives
up").

---

## The read model (views)

| view | what it gives you |
|---|---|
| `v_customer` / `v_product` / `v_order` | current, live subjects — column-for-column with the Anchor demo |
| `v_order_line` | order × product pairs, read back from group memberships |
| `v_res` | every resource, live or deleted, with its parent |
| `v_metric_sample` | every sample with names instead of surrogates |
| `v_metric_latest` | the newest sample per resource, metric and provider |
| `v_metric_weekly` | `METRIC_WEEKLY` with names |
| `v_group_weekly` | members' weekly values summed per group |
| `v_res_type_rel_violation` / `v_res_grp_path_violation` | integrity views; both must be empty |

---

## Make targets

| Target               | Effect                                                                |
|----------------------|-----------------------------------------------------------------------|
| `make demo`          | fresh archive + schema + the full delivery sequence + printed mart    |
| `make rebuild`       | regenerate the mart by replaying the raw layer                        |
| `make test`          | run the test suite (237 assertions)                                   |
| `make init`          | recreate the mart database from schema (the archive survives)         |
| `make clean`         | delete `build/` only — **the archive survives**                       |
| `make clean-archive` | delete `archive/` — destroys the raw layer and the ability to rebuild |

---

## Repository layout

```
.
├── Makefile
├── METRICSMART.md            # design notes: review of the ER diagrams, and the mart vs the sibling models
├── docs/
│   └── er-diagrams.md        # Mermaid ER diagrams, one per layer
├── schema/
│   ├── 01_landing.sql        # wide stage, narrow landing (shared shape) + routing metadata + load guard
│   ├── 02_archive.sql        # raw layer: append-only wide history (hist_*) + manifest + triggers
│   ├── 03_mart.sql           # staging and core tables from the diagrams, CALNDR, plus the added subtypes
│   ├── 04_seed.sql           # reference rows, CALNDR days for 2026-2027, and the routing maps
│   └── 05_views.sql          # business views, mart views, integrity views
├── scripts/
│   ├── lib.sh                # shared helpers; the single DB choke point (foreign keys ON); sql_tx; ensure_groups_sql
│   ├── init_db.sh            # (re)create the mart database; preserve the archive
│   ├── load_feed.sh          # ingest ONE delivery (stage → archive → stage narrow → apply → complete)
│   ├── stage_narrow.sh       # unpivot the wide stage into key/value rows (ingest AND replay)
│   ├── apply_delivery.sh     # the one path from staged rows to the mart (ingest AND replay)
│   ├── route_stage.sh        # narrow landing → RES_STG / METRIC_STG / ...; the delete rule
│   ├── load_res.sh           # resources, aliases, parents, subtype columns
│   ├── load_groups.sh        # groups, type groups and memberships
│   ├── load_metrics.sh       # METRIC_STG → METRIC_STG2 → METRIC_SAMPLE
│   ├── refresh_aggregates.sh # METRIC_SUMMARY, METRIC_WEEKLY, GRP_METRIC_WEEKLY
│   ├── rebuild.sh            # ordered replay of the archive
│   └── query.sh              # print the mart
├── source/                   # D0–D5, wide; byte-identical in all ten models
├── tests/
│   ├── run_tests.sh          # 237 assertions
│   └── fixtures/
│       ├── d6_tiebreak.sql           # same-extract tiebreak (identical to Anchor's)
│       ├── d7_repoint.sql            # O-101 re-pointed to C001 (identical to Anchor's)
│       ├── d8_metric_obs.sql         # a one-attribute delivery: a new price observation
│       ├── d8c_metric_correction.sql # a corrected sample and a second sample in one week
│       └── d9_lifecycle.sql          # restore, auto-created parent, membership tombstone
├── build/                    # generated: the mart (safe to delete)
└── archive/                  # generated: the durable raw layer
```

---

## Testing

```bash
make test
```

**237 assertions** (36 core, 201 model), pure shell + `sqlite3`. The output comes in two parts: CORE,
the fourteen sections every one of the ten suites runs in the same order with the same labels
(`../tests/core_spec.tsv`; the nine question answers are the SQL files in `tests/answers/`), then
MODEL, what only this model shows. The mart keeps current state only, so C001's earlier email
(C08.4) and O-101's earlier owner (C13.2) are answered from the raw archive, the final answer in
every model. One core assertion is a known GAP: C04.3, because an unchanged price seen again is a
new sample by design. Between them the parts cover:

- **Delete semantics** — the stale-window trap, FULL-absence deletes,
  tombstones, recency dedup, load control, a rejected re-use of a
  `file_id`, and a stale FULL snapshot that is not applied a second time.
- **Resources** — one table for three types, deterministic surrogates,
  aliases, parents, in-place updates that touch changed rows only, restore
  after delete, and a stub created for a parent no feed has delivered yet.
- **Metrics** — numeric attributes as samples, name resolution through
  `METRIC_STG2`, a re-observed value as a new sample, a corrected value
  overwriting its sample, and (at level 2, narrow) a one-attribute delivery
  leaving every other attribute alone.
- **Groups and aggregates** — groups built from paths, membership deletes by
  tombstone and by FULL absence, Monday weeks taken from `CALNDR`, a sample dated outside it rejected,
  a week averaging two samples,
  and aggregate rows restamped only when their numbers change.
- **Constraints** — an unknown order status rejected by its foreign key with
  the whole step rolled back, a parent pairing missing from `RES_TYPE_REL`
  rejected by the load guard, and both integrity views empty after every
  delivery.
- **Rebuild** — `make clean` + replay reproduces the mart exactly, after the
  shared scenario (by `rebuild.sh` and by `make rebuild`) and again after
  every fixture. Failed deliveries are not replayed. The archive holds no
  narrow table.
- **Reference data** — a status relabel takes effect with no reload, a new
  metric loads with no DDL in the mart (its delivery runs at level 2: the
  wide layout has no column for it), and a rebuild resets both to the
  schema seed.
- **The wide input** — `stage_narrow.sh` checked on its own (types, key
  rows, NULLs, tombstones, order); narrow fixtures fed straight to the
  loaders; and the old narrow D0–D5 (`tests/fixtures/narrow`) building the
  same mart, surrogate for surrogate, as the wide files.

See [METRICSMART.md](METRICSMART.md) for the mutation checks.

---

## What the metrics mart gives up

- **No history of descriptors.** `RES` is current state. After D1 the mart
  cannot say what C001's email used to be, and after the re-point it cannot
  say C002 ever owned O-101. Only the archive can. "As it was when the order
  was placed" is not a question this model answers.
- **Rows mutate.** Resources update in place and a corrected sample
  overwrites the old value. Focal and Anchor, the other models that load
  through the narrow landing, are insert-only.
- **Everything that isn't a number needs a column.** The model is generous
  to measurements and strict with descriptors: a new metric is a row, a new
  descriptive attribute is DDL on a populated table.
- **A new metric from a source needs a wide column.** The mart takes a new
  metric as a row, but the shared raw layer is wide: a metric a source
  starts sending (`weight_kg` in the suite) needs a new column in
  `stg_product_l1` and `hist_product`, which is DDL on a layout all ten
  models share. A native narrow archive avoids that, at the cost of
  switching (see above).
- **One parent per resource.** An order line has two parents, an order and a
  product, and `parent_res` holds one. The second has to become a group
  membership.
- **Aliases are not qualified by provider.** `RES_ALIAS` is keyed on
  `(res_type, res_alias)`. Two providers using the same name for different
  resources of one type would collide.
- **Group history is current membership.** `RES_RESGRP` has no dates, so a
  group's past weeks are recomputed with today's members.
- **Type groups cost rows.** Every resource is a member of its
  `/TYPE/<res_type>` group, and `GRP_METRIC_WEEKLY` carries a row per
  resource per type group per week. That is also a rollup by type for free.
- **The calendar ends.** `CALNDR` covers 2026 and 2027. A sample dated
  outside it fails the load until the table is extended.
- **Stubs can be wrong.** Auto-creating a parent keeps the load moving and
  puts a resource in the mart that no owning feed has confirmed. A FULL
  reconciliation from that feed will delete it.

---

## Going deeper

- **[METRICSMART.md](METRICSMART.md)** — a review of the ER diagrams, where
  this implementation follows them and where the shared discipline fills
  gaps, and how the mart compares with the sibling models.
- **[docs/er-diagrams.md](docs/er-diagrams.md)** — ER diagrams of every
  table, generated from the live schema: a keys-only overview and one
  full-column diagram per layer.
- **Sibling demos** — [`../v3_inmon-3nf`](../v3_inmon-3nf) is the other 3NF
  answer (time-variant entities, wide files);
  [`../v3_focal-point`](../v3_focal-point) and [`../v3_anchor`](../v3_anchor)
  unpivot the same wide files into the same narrow landing, then load
  generic and 6NF targets. The
  [top-level README](../README.md) sets out the comparison set.
