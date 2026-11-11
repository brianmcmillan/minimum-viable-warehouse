# Activity Schema: everything is something a customer did

A small, fully working [Activity Schema](https://github.com/ActivitySchema/ActivitySchema)
warehouse (Ahmed Elsamadisi's single-stream model, spec 2.0) built from
nothing but **`sqlite3`, `bash`, and `make`**. No Python, no dbt, no server,
no packages to install. Clone it, run `make demo`, and you have a warehouse
where every fact is a timestamped activity, every question is answered by
relating activities in time, deletes are handled safely under realistic feed
cadences, and the whole thing can be thrown away and rebuilt from a durable
raw layer.

The Activity Schema's bet is that facts and dimensions are the wrong
primitives. Model **an entity doing something at a moment** instead, put
every activity in one stream, and answer questions with a small set of
temporal relationships rather than foreign keys.

- **Streams, not entities.** `customer_stream` holds everything a customer
  did: signed up, changed email, placed an order. `product_stream` holds
  everything that happened to a product. One fixed set of columns per
  stream, the same for every activity.
- **Activities are immutable.** A changed value is a new activity
  (`updated_email`); a delete is a new activity (`was_deleted`). Triggers
  refuse `UPDATE` and `DELETE`.
- **Temporal joins, not foreign keys.** Current state is LAST EVER. "As it
  was when the order was placed" is LAST BEFORE. "What happened next" is
  FIRST AFTER. Activities relate by who (`customer`), what (`link`) and
  when (`ts`).
- **The honest part: snapshots in, events out.** The shared deliveries are
  state snapshots ("C001's email is X"), not events. The loader compares
  each delivery with the state the streams already imply and writes only
  the differences, so most of the work is change detection, as in every
  other model here.

> **Part of a nine-model comparison set.** This is the event-centric leg:
> one stream per entity, temporal joins instead of foreign keys. The same
> six logical deliveries run through nine warehouses
> ([Inmon 3NF EDW](../v3_inmon-3nf), [Kimball star](../v3_data-marts),
> [Data Vault 2.0](../v3_datavault), [Focal Point](../v3_focal-point),
> [Anchor](../v3_anchor), [HOOK](../v3_hook),
> [Unified Star Schema](../v3_unified-star-schema), this Activity Schema,
> and [One Big Table](../v3_one-big-table)), so every difference between
> them is the *model*, never the input. This model takes the wide,
> one-row-per-record restatement shared byte-for-byte by Inmon, Kimball,
> Data Vault, HOOK, USS, Activity Schema and OBT. Its archive uses the same
> layout (`loaded_files` + per-feed `hist_*` tables, append-only triggers)
> as the Inmon, Kimball, HOOK, USS and OBT archives. **This README stands on
> its own;** [ACTIVITY.md](ACTIVITY.md) draws the cross-model comparison.

---

## Requirements

| Tool      | Developed against       | Notes                                                        |
|-----------|-------------------------|--------------------------------------------------------------|
| `bash`    | 5.x (also runs on 3.2)  | the built-in macOS bash works                                |
| `sqlite3` | 3.37+                   | window functions and the JSON functions (built in from 3.38) |
| `make`    | 3.81+ (GNU Make)        | the stock macOS binary works                                 |

Everything runs against local files in this directory; nothing reaches the
network.

---

## Quick start

```bash
make demo          # fresh archive + schema + the full 6-delivery sequence, then print the warehouse
make rebuild       # delete the streams; replay the raw layer to rebuild them
make test          # 123 assertions: delete semantics, immutability, temporal joins, exact rebuild
make clean         # delete build/ only — the archive SURVIVES
make clean-archive # delete archive/ — destroys the raw layer, and the ability to rebuild
```

`make demo` loads six deliveries standing in for a few weeks of real feeds,
then prints the warehouse. The customer stream is the whole model:

```
### customer_stream
activity_id  ts                   customer  activity       link   revenue_impact  feature_json
-----------  -------------------  --------  -------------  -----  --------------  ------------------------------------------
cs-000001    2026-01-05 00:00:00  C001      signed_up                             {"full_name":"Alice Smith","email_addr":...}
cs-000003    2026-02-01 10:00:00  C001      placed_order   O-100  29.49           {"status":"P","amount":29.49,...}
cs-000005    2026-03-02 00:00:00  C001      updated_email                         {"email_addr":"alice@newmail.com"}
cs-000002    2026-01-06 00:00:00  C002      signed_up                             {"full_name":"Bob Jones",...}
cs-000004    2026-02-02 11:30:00  C002      placed_order   O-101  19.5            {"status":"P","amount":19.5,...}
cs-000006    2026-03-16 00:00:00  C002      was_deleted                           {"basis":"TOMBSTONE"}
cs-000007    2026-03-10 00:00:00  C003      signed_up                             {"full_name":"Carol Diaz","email_addr":"new@x.com",...}
cs-000008    2026-12-31 00:00:00  C003      was_deleted                           {"basis":"FULL_ABSENCE"}
```

Eight activities from six deliveries. D5 restated C001 unchanged and wrote
nothing for her. The order views are answered by temporal joins over those
rows:

```
### LAST BEFORE: each order against the profile as it was when placed
order_ref  placed_at            customer_ref  placed_by_at_purchase  email_at_purchase  placed_by_current
---------  -------------------  ------------  ---------------------  -----------------  -----------------
O-100      2026-02-01 10:00:00  C001          Alice Smith            alice@example.com  Alice Smith
O-101      2026-02-02 11:30:00  C002          Bob Jones              bob@example.com
```

`O-101` was placed by Bob Jones, who has since been deleted. The current
owner is gone, but the stream still answers who placed it, from the
activities that came before the order. No surrogate key was frozen to make
that possible; it is a join on time.

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

The Activity Schema spec says nothing about corrections or deletes. Here the
shared rule fills that gap: a delete is an activity like any other
(`was_deleted`, `discontinued`, `order_deleted`, `removed_from_order`) with
`feature_json.basis` recording *why* (`TOMBSTONE` or `FULL_ABSENCE`).

| event | Activity Schema (this demo) |
|---|---|
| attribute change | one `updated_<attr>` activity per changed attribute, carrying only that attribute |
| delete detected | a delete activity, `basis` = `TOMBSTONE` / `FULL_ABSENCE` |
| unchanged re-delivery | no difference from the streams' current state — writes nothing |
| re-pointed relationship | `order_reassigned` in the **new** owner's stream; the original `placed_order` is untouched |
| business rule (`P → PENDING`) | raw `'P'` in `feature_json`; decoded **on read** |
| row mutation | never — triggers refuse `UPDATE` and `DELETE` on both streams |

### The demo delivery sequence

| #  | Delivery                  | Feed / mode                | What it proves                                                                    |
|----|---------------------------|----------------------------|-----------------------------------------------------------------------------------|
| D0 | `d0_baseline.sql`         | all / FULL                 | initial full load of every feed                                                   |
| D1 | `d1_cust_win_day60.sql`   | CRM.CUSTOMER / INCREMENTAL | a 14-day window updates C001 and **does not** delete stale, absent C002           |
| D2 | `d2_prod_full_v2.sql`     | PIM.PRODUCT / FULL         | absence **does** delete a discontinued SKU                                        |
| D3 | `d3_cust_tombstone.sql`   | CRM.CUSTOMER / INCREMENTAL | an explicit `op='DELETE'` tombstone deletes C002 in an incremental feed           |
| D4 | `d4_cust_recency.sql`     | CRM.CUSTOMER / INCREMENTAL | adds C003; a repeated key resolves to the newest by `extract_dt`, not `MAX()`     |
| —  | re-send D1                | (same `file_id`)           | load control skips a duplicate delivery (exercised by `make test`)                |
| D5 | `d5_cust_yearly_full.sql` | CRM.CUSTOMER / FULL        | a yearly full reconciliation deletes C003, gone at source                         |

---

## How the warehouse is shaped

### The streams

Both streams have the spec's columns plus three implementation columns (the
spec reserves the `_` prefix for those):

| column | spec | here |
|---|---|---|
| `activity_id` | required | `cs-000001`, `ps-000001`, … in load order |
| `ts` | required | when the activity happened (see *Event time vs observed time*) |
| `customer` | required | the entity: a customer id in `customer_stream`, a SKU in `product_stream` (the spec keeps the column name) |
| `activity` | required | the verb, from `activity_catalog` |
| `feature_json` | required | the metadata this activity owns, under the source column names |
| `anonymous_customer_id` | optional | present, unused: the corpus has no pre-identification activity |
| `revenue_impact` | optional | the order amount on `placed_order` |
| `link` | optional | the `order_ref` on every order and order-line activity |
| `_seq` | implementation | load order; breaks ties between activities with the same `ts` |
| `_load_ts`, `_record_source` | implementation | lineage: the batch timestamp and delivery id, as in every sibling |

Orders are not an entity. An order is something a customer does, so
`placed_order`, `order_updated`, `order_reassigned` and `order_deleted`
live in the owner's `customer_stream`, tied together by `link`. Order lines
are something that happens to a product: `was_ordered` in `product_stream`.

There are no entity tables. The spec allows one per stream for current
metadata, but it would be a mutable copy of what the streams already say,
so current state is a view.

### The activity catalog

`activity_catalog` lists every activity, where its `ts` comes from, and what
it is authoritative for. The suite checks after every delivery that no
stream holds an activity missing from it.

| stream | activities |
|---|---|
| `customer_stream` | `signed_up`, `updated_name`, `updated_email`, `updated_signup_date`, `was_deleted`, `restored`, `placed_order`, `order_updated`, `order_reassigned`, `order_deleted`, `order_restored` |
| `product_stream` | `added`, `updated_name`, `updated_price`, `updated_currency`, `discontinued`, `restored`, `was_ordered`, `removed_from_order` |

### Event time vs observed time

An activity's `ts` should be when it happened. The deliveries only
sometimes say:

- **Event time** where the source has one: `signed_up` uses `signup_date`;
  `placed_order` and `was_ordered` use the order's `placed_at`.
- **Observed time** otherwise: `updated_email` is stamped with the extract
  it was first seen in. The CRM never says when Alice changed her email,
  only that D1's extract had the new one.
- **Snapshot time** for absence deletes: the FULL delivery's extract date.

This shows up in the data. SKU-1's `was_ordered` (2026-02-01, the order's
event time) comes *before* its `added` (2026-02-05, when the catalogue was
first observed). And `signed_up` carries the profile as first observed,
stamped at signup, which assumes nothing changed between signup and the
first extract. That is the one assumption the "as at purchase" answers rest
on, and the design notes say so.

---

## The loader: snapshots in, differences out

`scripts/load_activities.sh` handles each feed in a fixed order (customers,
products, orders, order lines). For each staged subject it compares the
delivery with the current state the streams imply (`v_*_state`, the spec's
LAST EVER) and emits:

| situation | activity |
|---|---|
| never seen | `signed_up` / `added` / `placed_order` / `was_ordered` |
| deleted, delivered again | `restored` / `order_restored` / `was_ordered` |
| alive, value changed | one `updated_<attr>` per changed attribute, or `order_updated` |
| order's customer changed | `order_reassigned`, in the new owner's stream, `from_customer` recorded |
| tombstone, alive | the feed's delete activity, `basis` `TOMBSTONE` |
| FULL delivery, alive, absent | the feed's delete activity, `basis` `FULL_ABSENCE` |
| alive, unchanged | nothing |

Every emit continues `_seq` and `activity_id` from the stream's maximum, in
a fixed order (step, then business key). That is what lets an ordered replay
of the archive reproduce every activity exactly, ids included.

---

## The two databases: disposable streams over a durable raw layer

- **`build/activity.db`** — stage, streams, views. **Throwaway.**
- **`archive/activity_archive.db`** — every delivery ever accepted, captured
  *verbatim and before it is applied*, append-only, plus a `loaded_files`
  manifest. **Durable.** `make clean` never touches it. Its layout is the
  same as the Inmon, Kimball, HOOK, USS and OBT archives.

The streams look like a log, so why keep a separate archive? Because they
are a log of *differences*: an unchanged restatement writes nothing, and the
stage-L2 dedup drops the losing duplicate. The archive keeps what the
streams drop, so `make rebuild` can replay every delivery in its original
order through the *same* `apply_delivery.sh` path that ingested it. The
suite asserts the rebuilt streams are identical, down to each activity's
`activity_id`, `_seq` and lineage.

### How a delivery flows

1. **Stage** the delivery into `stg_*_l1`; record `batch_ts` and `file_id` in
   `act_load_params`.
2. **Load control** — skip a `file_id` already `COMPLETE`; reject a reused
   `file_id` with a different row count.
3. **Archive** the staged rows verbatim (`INSERT OR IGNORE`, safe to retry).
4. **Apply** via `apply_delivery.sh` → `load_activities.sh`.
5. **Mark COMPLETE**, then clear the stage. A crash leaves the delivery
   `STARTED` with its staged rows in place as forensics.

---

## The read model (views)

| view | what it gives you |
|---|---|
| `v_customer` / `v_product` | current, non-deleted subjects — column-for-column with the sibling demos |
| `v_order` | current orders; status decoded **on read**; `placed_by` = the current owner, if alive |
| `v_order_line` | current order × product pairs |
| `v_order_at_purchase` | **LAST BEFORE**: each order with the placing customer's name and email as they were when it was placed |
| `v_order_ownership` | every activity that put an order in a customer's stream, read against its own moment |
| `v_customer_journey` | **FIRST EVER / FIRST AFTER**: signup, first order, days between, the next email change after it |
| `v_customer_history` / `v_product_history` | every activity, with lineage |
| `v_customer_state` / `v_product_state` / `v_order_state` / `v_order_line_state` | **LAST EVER**: current state per subject; the loader's change detection reads these |

---

## Make targets

| Target               | Effect                                                                   |
|----------------------|--------------------------------------------------------------------------|
| `make demo`          | fresh archive + schema + the full delivery sequence + printed warehouse  |
| `make rebuild`       | regenerate the streams by replaying the raw layer                        |
| `make test`          | run the test suite (123 assertions)                                      |
| `make init`          | recreate the activity database from schema (the archive survives)        |
| `make clean`         | delete `build/` only — **the archive survives**                          |
| `make clean-archive` | delete `archive/` — destroys the raw layer and the ability to rebuild    |

---

## Repository layout

```
.
├── Makefile
├── ACTIVITY.md              # design notes: the Activity Schema vs the sibling models
├── schema/
│   ├── 01_stage.sql         # stage L1 tables (shared shape) + L2 recency-dedup views
│   ├── 02_archive.sql       # raw layer: append-only wide history + manifest + triggers
│   ├── 03_activity.sql      # the two streams, immutability triggers, activity catalog, state views
│   └── 04_views.sql         # business views and the temporal-join views
├── scripts/
│   ├── lib.sh               # shared helpers; the single DB choke point
│   ├── init_db.sh           # (re)create the activity database; preserve the archive
│   ├── load_feed.sh         # ingest ONE delivery (stage → archive → apply → complete)
│   ├── apply_delivery.sh    # the one path from staged rows to activities (ingest AND replay)
│   ├── load_activities.sh   # snapshot → activities: change detection + the shared delete rule
│   ├── rebuild.sh           # ordered replay of the archive
│   └── query.sh             # print the warehouse
├── source/                  # D0–D5, byte-identical with the other wide-shape demos
├── tests/
│   ├── run_tests.sh         # 123 assertions
│   └── fixtures/
│       ├── d6_repoint.sql   # O-101 re-pointed to C001 (data row identical to the siblings')
│       ├── d7_lifecycle.sql # restore, order status change, line tombstone
│       └── d8_tiebreak.sql  # same-extract tiebreak + key-ordered activity ids
├── build/                   # generated: the streams (safe to delete)
└── archive/                 # generated: the durable raw layer
```

---

## Testing

```bash
make test
```

**123 assertions**, pure shell + `sqlite3`, covering:

- **Delete semantics** — the stale-window trap, FULL-absence deletes,
  tombstones, recency dedup, load control, and zero-activity idempotence.
- **Snapshots to activities** — first sightings, one activity per changed
  attribute, NOCHANGE writes nothing, event time vs observed time, and every
  activity listed in the catalog (checked after every delivery).
- **Immutability** — `UPDATE`/`DELETE` abort on both streams and the archive;
  `activity_id` and `_seq` dense and unique.
- **Temporal joins** — LAST EVER current state, LAST BEFORE at-purchase
  answers that survive a later change and a delete, FIRST EVER / FIRST AFTER
  journeys, and no foreign keys anywhere.
- **The D6 re-point** — `order_reassigned` in the new owner's stream, the
  original `placed_order` untouched, ownership read against each moment, and
  a re-sent re-point writes nothing.
- **Lifecycle and ordering fixtures** — restore after delete, an order status
  change, a line tombstone, a same-extract tiebreak, and activity ids in
  business-key order rather than staged order.
- **Rebuild** — `make clean` + replay reproduces both streams exactly, twice:
  after the shared scenario and again after every fixture.

Mutation-checked: removing the FULL guard, the NOCHANGE guard, the tombstone
branch, the restore path or an immutability trigger; reversing the dedup
tiebreak, the replay order or the replay row order; stamping `signed_up`
with the extract date instead of the event; reading "at purchase" from
current state; and writing no activity for a re-point each turn the suite
red. Dropping the business-key sort from activity numbering survives on the
SQLite build it was checked against, because the engine's plan happens to
return the same order; the fixture assertion guards it on other engines.

---

## What the Activity Schema gives up

- **Snapshot feeds fight the model.** The spec assumes event sources. With
  state snapshots, the loader has to diff every delivery against the
  streams, which is the same change-detection work every other model does,
  just with a different output.
- **Observed time is not event time.** Most attribute changes can only be
  stamped when they were seen. Point-in-time answers are only as good as
  those timestamps, and the first-observed profile is attributed to signup.
- **Non-customer things are awkward.** Orders have no stream of their own,
  so order state is assembled from customer activities by `link`, and a
  re-point is a special activity. Order lines become product activities.
- **Current state is always a query.** "List the customers" is LAST EVER per
  attribute over the whole stream. That's cheap here and not free at scale,
  which is why real implementations add entity tables or materializations.
- **The spec is silent on deletes and corrections.** Everything about them
  here is the shared discipline, not the Activity Schema.
- **`feature_json` is untyped.** Attribute values live in JSON; the schema
  enforces nothing about them.

---

## Going deeper

- **[ACTIVITY.md](ACTIVITY.md)** — what the Activity Schema is, where this
  implementation follows the spec and where the shared discipline fills
  gaps, and how it compares with the sibling models.
- **Sibling demos** — [`../v3_one-big-table`](../v3_one-big-table) is the
  other one-table answer (state rather than activities);
  [`../v3_data-marts`](../v3_data-marts) answers "as at purchase" with
  frozen surrogate keys instead of a temporal join. The
  [top-level README](../README.md) sets out the full set.
