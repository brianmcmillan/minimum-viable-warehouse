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
- **Calendar events target groups.** An event applies to one resource, a
  group, a sub-group or a whole resource type, and every one of those is a
  `RES_GRP`. The event is stored against the group's surrogate key, so it
  stays attached when a resource's code changes. Events belong to named
  event groups, and every metric sample can be read next to the events in
  effect for its resource that day.

> **Runs the same deliveries as the nine-model comparison set**
> ([Inmon 3NF EDW](../v3_inmon-3nf), [Kimball star](../v3_data-marts),
> [Data Vault 2.0](../v3_datavault), [Focal Point](../v3_focal-point),
> [Anchor](../v3_anchor), [HOOK](../v3_hook),
> [Unified Star Schema](../v3_unified-star-schema),
> [Activity Schema](../v3_activity-schema) and
> [One Big Table](../v3_one-big-table)). This model takes the narrow,
> one-row-per-attribute files shared byte-for-byte with Focal Point and
> Anchor, and its archive uses their layout (`loaded_files` +
> `source_landing_history`, append-only triggers). The target is different:
> a 3NF model with real columns and real foreign keys. **This README stands
> on its own;** [METRICSMART.md](METRICSMART.md) reviews the ER diagrams and
> draws the cross-model comparison.

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
make test          # 220 assertions: delete semantics, samples, aggregates, calendar, exact rebuild
make clean         # delete build/ only — the archive SURVIVES
make clean-archive # delete archive/ — destroys the raw layer, and the ability to rebuild
```

`make demo` loads the six shared deliveries standing in for a few weeks of
real feeds, then one calendar delivery of its own, and prints the mart. One table holds every resource:

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
| C1 | `c1_calendar.sql`         | OPS.CALNDR_EVENT / FULL    | five calendar events in three event groups, one at each target level          |

D0–D5 in `source/` are byte-identical with the Focal and Anchor demos. C1 is
in `source_ext/` because no sibling has a calendar.

---

## How the shared corpus maps onto the mart

The mart was drawn for resources that get measured. The shared corpus is
customers, products and orders. The mapping is a few rows of metadata.

| in the narrow delivery | in the mart |
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
| a calendar event (`OPS.CALNDR_EVENT`, key `NEWYEAR`) | a `CALNDR_EVENT` row on a `RES_GRP`, found by its `group_path` |

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
| calendar | `CALNDR`, `CAL_EVT_TYPE`, `CALNDR_EVENT`, `CALNDR_EVENT_STG` (and `CAL_EVT_GRP`, added below) |

Column names and declared types are the diagrams'. Foreign keys are real and
switched on for every connection.

### Not built

`TIME_ZONE`, `TZ_CODE`, `COUNTRY` and `RAW_RES_TYPE` are extensions to the
model and are left out. Every `*_tz_code` column is `'UTC'`, and local timestamps equal UTC
ones. `site_id`, `support_ctr_id` and `client_id` point at tables the
diagrams don't show; they are plain nullable columns here.

### Added

- **Unique keys** on `RES (res_type, res_code)`, `METRIC.metric_code`,
  `PROVIDER.provider_name` and `RES_GRP.group_path`. The diagrams show only
  the surrogate primary keys.
- **Three subtype tables** (`RES_CUSTOMER`, `RES_PRODUCT`, `RES_ORDER`) and
  **two code tables** (`ORDER_STATUS`, `CURRENCY`). `RES` has a name, a short
  name and a description. The corpus also carries an email, a signup date, a
  currency, a status and a placed-at time, and in a 3NF model those belong in
  subtype tables keyed on `res_id`.
- **A different target for calendar events.** The diagram keys
  `CALNDR_EVENT` and its staging table on `res_type` + `res_code`. Here they
  carry `res_grp_id` and `group_path` instead, plus an `event_code` business
  key so a later delivery can change or delete an event. See *Calendar
  events* below.
- **`CAL_EVT_GRP`, the table behind `event_grp_id`.** The diagram has the
  column and no table for it. Here it is a named set of related events (a
  holiday calendar, an operations calendar, a promotions calendar). The feed
  names the group by code, and a new code creates the group.
- **Two readings of unexplained columns.** `srcd_ts` is taken as "when the
  mart last recorded a change to this row" (the batch timestamp). `srcd_d2k`
  on `METRIC_SAMPLE` is taken as that same date in whole days since
  2000-01-01. Both are assumptions.

### Routing metadata

Two small tables decide where each narrow row goes. No loader names a feed
or an attribute.

| table | one row per | says |
|---|---|---|
| `meta_feed_map` | feed | whether its keys are resources (and of which type), group memberships or calendar events |
| `meta_attribute_map` | attribute | `KEY`, `RES_COL`, `SUBTYPE` (table and column), `PARENT` (parent type), `METRIC` (metric code) or `EVENT_COL` (staging column) |

This is the Focal and Anchor idea pointed at a 3NF target, and it works to a
point. A new **metric** is two rows (one in `METRIC`, one in the map) with no
DDL and no loader change; the suite proves it. A new **descriptive
attribute** still needs a column first, because this is 3NF. Only its
routing is metadata.

---

## Calendar events

An event can apply at very different levels: a holiday for everything, a
maintenance window for every product, a freeze for the products on any
order, a review for one customer. Every level is a group, and each event
points at one.

| target | path | members |
|---|---|---|
| a resource type | `/TYPE/<res_type>` | every resource of the type; created for every type and kept current on every delivery |
| a single resource | `/RES/<res_type>/<res_code>` | that one resource; created the first time an event targets it |
| any other group | e.g. `/ORDER/O-100` | its members, as loaded from the feeds |

`inheritance_flag = 1` carries an event from its group to every group below
it. NEWYEAR on `/TYPE` reaches every resource through the type groups.
ORDER-FREEZE on `/ORDER` reaches the products in every order group, and with
the flag at 0 it reaches nothing, because `/ORDER` has no members of its own.

Membership is by `res_id`, so a resource whose code changes keeps its
events. The suite recodes C001 and checks that C001-REVIEW still reaches it.
Keyed on `res_type` + `res_code`, as in the diagram, the event would have
been orphaned.

A recurring event expands against `CALNDR`, one row per day for 2026 and
2027. The masks are `'Y'`/`'N'` strings: `days_of_week` is Monday first,
`months` January first. An event that sets no mask is a one-off on
`event_start_dt`.

```
### Occurrences per event and the resources each one reaches
event_code    dates  first_dt    last_dt     live_resources
------------  -----  ----------  ----------  ----------------------------
C001-REVIEW   6      2027-01-31  2027-06-30  C001
NEWYEAR       1      2027-01-01  2027-01-01  C001,O-100,O-101,SKU-1,SKU-2
ORDER-FREEZE  1      2027-12-31  2027-12-31  SKU-1,SKU-2
PIM-MAINT     5      2027-01-03  2027-01-31  SKU-1,SKU-2
SPRING-SALE   7      2026-03-01  2026-03-07  SKU-1,SKU-2
```

Events belong to event groups through `event_grp_id`. The demo has three:
HOLIDAYS-2027, OPS-2027 and PROMOS-2026. C001-REVIEW belongs to none, which
is allowed. A group lets a question cover a whole calendar at once: "every
operations date that touches SKU-2" is one filter on `event_grp_code`.

### Samples in their calendar context

`v_metric_sample_event` joins every metric sample to the events in effect
for its resource on the sample's day:

```
### Metric samples with the calendar events active that day
res_code  metric_code  sample_dt   value  event_code   event_grp    cal_evt_type
--------  -----------  ----------  -----  -----------  -----------  ------------
SKU-1     price        2026-03-02  8.99   SPRING-SALE  PROMOS-2026  PROMOTION
SKU-2     price        2026-03-02  19.5   SPRING-SALE  PROMOS-2026  PROMOTION
```

SKU-1's price fell from 9.99 to 8.99 on 2026-03-02. Read alone, that is a
change somebody has to investigate. Read with the calendar, it happened
during a planned promotion. A decision layer on top of this mart needs that
join before it calls anything a signal. See *Why the calendar matters* in
[METRICSMART.md](METRICSMART.md).

Events follow the shared delete rule: a tombstone always deletes, and
absence deletes only under a FULL calendar delivery. A delivery that names
one attribute of an event changes that attribute and keeps the rest. A
target group that doesn't exist, a `/RES/` path for an unknown resource and
an unknown `cal_evt_type` each fail the load.

---

## The loaders

`scripts/apply_delivery.sh` is the one path from staged rows to the mart,
used by both ingest and replay.

1. **Landing.** Replace each delivered feed's rows in `source_landing`,
   keeping the newest per key and attribute by `extract_ts`, ties broken by
   file order.
2. **Route** (`route_stage.sh`). Fill `RES_STG`, `RES_ALIAS_STG`,
   `METRIC_STG`, `RES_RESGRP_STG` and `CALNDR_EVENT_STG`. Apply the delete
   rule.
3. **Resources** (`load_res.sh`). Create providers and new resources,
   resolve parents through `RES_ALIAS`, update changed descriptors, restore
   or delete by `load_oper`, then set subtype columns one generated statement
   per mapped attribute.
4. **Groups** (`load_groups.sh`). Create groups from their paths, keep the
   type groups current and reconcile memberships.
5. **Calendar** (`load_calendar.sh`). Create single-resource groups that
   events target, then insert, update and delete events.
6. **Metrics** (`load_metrics.sh`). Resolve `METRIC_STG` into `METRIC_STG2`
   and upsert `METRIC_SAMPLE`.
7. **Aggregates** (`refresh_aggregates.sh`). Recompute daily summaries,
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
  Focal and Anchor archive's.

The archive matters more here than in most of the siblings. `RES` keeps no
history, so the raw layer is the only place an earlier email, an earlier
parent or a corrected sample value can still be found.

`make rebuild` replays every completed delivery in its original order
through the *same* `apply_delivery.sh` path that ingested it. The suite
asserts the rebuilt mart is identical, down to each `res_id`, `provider_id`,
`res_grp_id` and `srcd_ts`.

### How a delivery flows

1. **Stage** the delivery into `source_landing_stage`.
2. **Load control** — skip a `file_id` already `COMPLETE`; reject a reused
   `file_id` whose content differs from what was archived.
3. **Archive** the staged rows verbatim (`INSERT OR IGNORE`, safe to retry).
   The archive's `load_seq` becomes the mart's `batch_no`.
4. **Apply** via `apply_delivery.sh`.
5. **Mark COMPLETE**, then clear the stage. A crash leaves the delivery
   `STARTED` with its staged rows in place as forensics.

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
| `v_calndr_event` | every event with its target group's path |
| `v_calndr_occurrence` | every date each event falls on, inside the `CALNDR` range |
| `v_res_calendar` | every resource each occurrence reaches, through membership and inheritance |
| `v_metric_sample_event` | every metric sample with the events in effect for its resource that day |
| `v_res_type_rel_violation` / `v_res_grp_path_violation` | integrity views; both must be empty |

---

## Make targets

| Target               | Effect                                                                |
|----------------------|-----------------------------------------------------------------------|
| `make demo`          | fresh archive + schema + the full delivery sequence + printed mart    |
| `make rebuild`       | regenerate the mart by replaying the raw layer                        |
| `make test`          | run the test suite (220 assertions)                                   |
| `make init`          | recreate the mart database from schema (the archive survives)         |
| `make clean`         | delete `build/` only — **the archive survives**                       |
| `make clean-archive` | delete `archive/` — destroys the raw layer and the ability to rebuild |

---

## Repository layout

```
.
├── Makefile
├── METRICSMART.md            # design notes: review of the ER diagrams, and the mart vs the sibling models
├── schema/
│   ├── 01_landing.sql        # narrow landing (shared shape) + routing metadata + load guard
│   ├── 02_archive.sql        # raw layer: append-only narrow history + manifest + triggers
│   ├── 03_mart.sql           # staging, core and calendar tables from the diagrams, plus the added subtypes
│   ├── 04_seed.sql           # reference rows, CALNDR days for 2026-2027, and the routing maps
│   └── 05_views.sql          # business views, mart views, calendar views, integrity views
├── scripts/
│   ├── lib.sh                # shared helpers; the single DB choke point (foreign keys ON); sql_tx; ensure_groups_sql
│   ├── init_db.sh            # (re)create the mart database; preserve the archive
│   ├── load_feed.sh          # ingest ONE delivery (stage → archive → apply → complete)
│   ├── apply_delivery.sh     # the one path from staged rows to the mart (ingest AND replay)
│   ├── route_stage.sh        # narrow landing → RES_STG / METRIC_STG / ...; the delete rule
│   ├── load_res.sh           # resources, aliases, parents, subtype columns
│   ├── load_groups.sh        # groups, type groups and memberships
│   ├── load_calendar.sh      # single-resource groups and calendar events
│   ├── load_metrics.sh       # METRIC_STG → METRIC_STG2 → METRIC_SAMPLE
│   ├── refresh_aggregates.sh # METRIC_SUMMARY, METRIC_WEEKLY, GRP_METRIC_WEEKLY
│   ├── rebuild.sh            # ordered replay of the archive
│   └── query.sh              # print the mart
├── source/                   # D0–D5, byte-identical with the Focal and Anchor demos
├── source_ext/
│   └── c1_calendar.sql       # five calendar events in three event groups; this demo only
├── tests/
│   ├── run_tests.sh          # 220 assertions
│   └── fixtures/
│       ├── d6_tiebreak.sql           # same-extract tiebreak (identical to Anchor's)
│       ├── d7_repoint.sql            # O-101 re-pointed to C001 (identical to Anchor's)
│       ├── d8_metric_obs.sql         # a one-attribute delivery: a new price observation
│       ├── d8c_metric_correction.sql # a corrected sample and a second sample in one week
│       ├── d9_lifecycle.sql          # restore, auto-created parent, membership tombstone
│       ├── c2_calendar_changes.sql   # a one-attribute change, a tombstone, an event moved to a new group
│       └── c3_calendar_full.sql      # a FULL calendar delivery listing one event
├── build/                    # generated: the mart (safe to delete)
└── archive/                  # generated: the durable raw layer
```

---

## Testing

```bash
make test
```

**220 assertions**, pure shell + `sqlite3`, covering:

- **Delete semantics** — the stale-window trap, FULL-absence deletes,
  tombstones, recency dedup, load control, a rejected re-use of a
  `file_id`, and a stale FULL snapshot that is not applied a second time.
- **Resources** — one table for three types, deterministic surrogates,
  aliases, parents, in-place updates that touch changed rows only, restore
  after delete, and a stub created for a parent no feed has delivered yet.
- **Metrics** — numeric attributes as samples, name resolution through
  `METRIC_STG2`, a re-observed value as a new sample, a corrected value
  overwriting its sample, and a one-attribute delivery leaving every other
  attribute alone.
- **Groups and aggregates** — groups built from paths, membership deletes by
  tombstone and by FULL absence, Monday weeks, a week averaging two samples,
  and aggregate rows restamped only when their numbers change.
- **Constraints** — an unknown order status rejected by its foreign key with
  the whole step rolled back, a parent pairing missing from `RES_TYPE_REL`
  rejected by the load guard, and both integrity views empty after every
  delivery.
- **Rebuild** — `make clean` + replay reproduces the mart exactly, twice:
  after the shared scenario and again after every fixture. Failed deliveries
  are not replayed.
- **Calendar** — an event at each level (type, all types, sub-groups, one
  resource), recurrence by weekday, month end, month and year, inheritance
  switched on and off, event groups created from the feed and an event moved
  between them, a one-attribute change, tombstone and FULL-absence deletes,
  three kinds of bad delivery rejected with nothing written, samples matched
  to the events in effect that day, and a recoded resource keeping its
  events.
- **Reference data** — a status relabel takes effect with no reload, a new
  metric loads with no DDL, and a rebuild resets both to the schema seed.

See [METRICSMART.md](METRICSMART.md) for the mutation checks.

---

## What the metrics mart gives up

- **No history of descriptors.** `RES` is current state. After D1 the mart
  cannot say what C001's email used to be, and after the re-point it cannot
  say C002 ever owned O-101. Only the archive can. "As it was when the order
  was placed" is not a question this model answers.
- **Rows mutate.** Resources update in place and a corrected sample
  overwrites the old value. Every other narrow-shape sibling is insert-only.
- **Everything that isn't a number needs a column.** The model is generous
  to measurements and strict with descriptors: a new metric is a row, a new
  descriptive attribute is DDL on a populated table.
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
- **One calendar feed is assumed.** Absence from a FULL calendar delivery
  deletes every event the mart holds that the delivery left out. A second
  calendar feed would need events tagged with their source.
- **The calendar ends.** `CALNDR` covers 2026 and 2027, and recurring events
  expand only inside it. `occurs_of_month` matches the nth weekday;
  `CALNDR.last_occur_flag` is loaded but no event mask uses it yet.
- **Stubs can be wrong.** Auto-creating a parent keeps the load moving and
  puts a resource in the mart that no owning feed has confirmed. A FULL
  reconciliation from that feed will delete it.

---

## Going deeper

- **[METRICSMART.md](METRICSMART.md)** — a review of the ER diagrams, where
  this implementation follows them and where the shared discipline fills
  gaps, and how the mart compares with the sibling models.
- **Sibling demos** — [`../v3_inmon-3nf`](../v3_inmon-3nf) is the other 3NF
  answer (time-variant entities, wide files);
  [`../v3_focal-point`](../v3_focal-point) and [`../v3_anchor`](../v3_anchor)
  load the same narrow files into generic and 6NF targets. The
  [top-level README](../README.md) sets out the comparison set.
