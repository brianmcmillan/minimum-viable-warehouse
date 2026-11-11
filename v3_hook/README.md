# HOOK: frames, hooks, and nothing else

A small, fully working HOOK warehouse —
Andrew Foad's approach to keeping the warehouse source-shaped — built from nothing but
**`sqlite3`, `bash`, and `make`**. No Python, no dbt, no server, no packages
to install. Clone it, run `make demo`, and you have a warehouse that keeps
every source table almost exactly as it arrived, hooks each row to the
business concepts it is about, handles deletes safely under realistic feed
cadences, and can delete itself and rebuild from a durable raw layer.

HOOK's bet is that most of what other models build up front — hubs, links,
dimensions, surrogates, conformed entities — can be **deferred to views**,
as long as you do one thing right on the way in: qualify every business key
with the system that minted it.

- **Frames, not entities.** One frame per source table: the source columns
  verbatim, plus hook columns, plus load metadata. Insert-only and
  delta-compressed — an unchanged restatement writes nothing.
- **Hooks, not hubs.** A hook is `'<key set>|<business key>'`, e.g.
  `CRM.CUST|C001`, stored as an `hk_<concept>` column. Rows that carry the
  same hook are about the same thing. That is the whole integration.
- **Relationships are just more hooks.** The order row carries `hk_order`
  *and* `hk_customer`. There are no link tables; the relationship lives on
  the row that asserts it.
- **The model is a registry.** Core Business Concepts, key sets, frames, and
  which hook columns sit on which frame are *rows* in four small tables.
  One generic loader reads them and loads every frame.

> **Part of a nine-model comparison set.** This is the hooks-only leg: Data
> Vault without the hub. The same six logical deliveries run through nine
> warehouses ([Inmon 3NF EDW](../v3_inmon-3nf),
> [Kimball star](../v3_data-marts), [Data Vault 2.0](../v3_datavault),
> [Focal Point](../v3_focal-point), [Anchor](../v3_anchor), this HOOK,
> [Unified Star Schema](../v3_unified-star-schema),
> [Activity Schema](../v3_activity-schema), and
> [One Big Table](../v3_one-big-table)), so every difference between them is
> the *model*, never the input. This model takes the wide,
> one-row-per-record restatement shared byte-for-byte by Inmon, Kimball,
> Data Vault, HOOK, USS, Activity Schema and OBT. Its archive uses the same
> layout (`loaded_files` + per-feed `hist_*` tables, append-only triggers)
> as the Inmon, Kimball, USS, Activity Schema and OBT archives. **This
> README stands on its own;** [HOOK.md](HOOK.md) draws the cross-model
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
make rebuild       # delete the frames; replay the raw layer to rebuild them
make test          # 99 assertions: delete semantics, hooks, delta frames, as-of, exact rebuild
make clean         # delete build/ only — the archive SURVIVES
make clean-archive # delete archive/ — destroys the raw layer, and the ability to rebuild
```

`make demo` loads six deliveries standing in for a few weeks of real feeds,
then prints the warehouse. The customer frame is the clearest picture of
what HOOK stores:

```
### frame__crm__customer
 hk_customer    full_name      email_addr      change_type  delete_basis        load_ts        record_source
-------------  -----------  -----------------  -----------  ------------  -------------------  -------------
CRM.CUST|C001  Alice Smith  alice@example.com  INSERT                     2026-02-05 08:00:00  B0
CRM.CUST|C001  Alice Smith  alice@newmail.com  UPDATE                     2026-03-02 08:00:00  D1
CRM.CUST|C002  Bob Jones    bob@example.com    INSERT                     2026-02-05 08:00:00  B0
CRM.CUST|C002                                  DELETE       TOMBSTONE     2026-03-16 08:00:00  D3
CRM.CUST|C003  Carol Diaz   new@x.com          INSERT                     2026-04-02 08:00:00  D4
CRM.CUST|C003                                  DELETE       FULL_ABSENCE  2026-12-31 08:00:00  D5
```

Six rows for six deliveries' worth of customer traffic. The D5 yearly
snapshot re-sent C001 unchanged and wrote nothing for it; it wrote one row,
the delete it discovered. And the "hub" nobody built:

```
### Concept members
concept       hook           first_seen       n_frames                    frames
--------  -------------  -------------------  --------  ------------------------------------------
CUSTOMER  CRM.CUST|C001  2026-02-05 08:00:00         2  frame__crm__customer,frame__oms__order
CUSTOMER  CRM.CUST|C002  2026-02-05 08:00:00         2  frame__crm__customer,frame__oms__order
CUSTOMER  CRM.CUST|C003  2026-04-02 08:00:00         1  frame__crm__customer
...
```

`v_concept_member` is a `GROUP BY` over every hook on every frame. Data
Vault materialises this as a hub table that every load must write first;
HOOK derives it when someone asks.

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

In HOOK a delete is a frame row like any other — `change_type='DELETE'`, with
`delete_basis` recording *why* (`TOMBSTONE` or `FULL_ABSENCE`). Because
frames are delta-compressed, absence cannot be reconstructed from them later,
so the loader must write the delete at load time. (One Big Table, which keeps
every restatement, can derive it on read instead; that is the trade.)

| event | HOOK (this demo) |
|---|---|
| attribute change | a new frame row, `change_type='UPDATE'` |
| delete detected | a new frame row, `change_type='DELETE'`, `delete_basis` = `TOMBSTONE` / `FULL_ABSENCE` |
| unchanged re-delivery | `diff_str` matches the latest row — writes nothing |
| re-pointed relationship | a new order row whose `hk_customer` changed |
| business rule (`P → PENDING`) | raw `'P'` in the frame; decoded **on read** |
| row mutation | never — triggers refuse `UPDATE` and `DELETE` on frames |

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

```
                     source deliveries (op / load_mode rows)
                                   │
                    ┌──────────────▼───────────────┐
                    │  stg_*_l1        (stage L1)   │  one wide table per feed
                    │      → v_stg_*_l2 (views)     │  dedup + HOOKS + diff_str
                    └──────────────┬───────────────┘
                                   │  load_frames.sh (ONE generic engine,
                                   │  driven by the hook_frame registry)
                                   ▼
          ┌──────────────────────────────────────────────────────┐
          │ frame__crm__customer   frame__pim__product           │  source-aligned,
          │ frame__oms__order      frame__oms__order_line        │  insert-only,
          │   + hook_concept / hook_keyset / hook_frame /        │  delta-compressed
          │     hook_column  (the registry IS the model)         │
          └──────────────────────────┬───────────────────────────┘
                                     ▼
          ┌──────────────────────────────────────────────────────┐
          │ v_latest__*  →  v_customer / v_product / v_order     │  everything
          │ v_order_as_recorded   v_concept_member (hub on demand)│  business-shaped
          │ v_hook_violation (key-set integrity)                 │  is a view
          └──────────────────────────────────────────────────────┘
```

### The registry

| Table          | Holds                                                                    |
|----------------|--------------------------------------------------------------------------|
| `hook_concept` | the Core Business Concepts: `CUSTOMER`, `PRODUCT`, `ORDER` — glossary entries, not tables |
| `hook_keyset`  | key sets and the concept each identifies: `CRM.CUST`, `PIM.SKU`, `OMS.ORD` |
| `hook_frame`   | one row per frame: stage table, stage view, frame key, business-key columns, load order |
| `hook_column`  | every `hk_*` column on every frame and the key set its values must use   |

### The frames

| Frame                    | Hooks                          | Grain                    |
|--------------------------|--------------------------------|--------------------------|
| `frame__crm__customer`   | `hk_customer`                  | one row per customer change |
| `frame__pim__product`    | `hk_product`                   | one row per product change |
| `frame__oms__order`      | `hk_order`, `hk_customer`      | one row per order change (re-points included) |
| `frame__oms__order_line` | `hk_order`, `hk_product`       | one row per order × product change |

Every frame also carries `extract_dt`, `change_type`, `delete_basis`,
`diff_str`, `load_ts`, and `record_source` (the delivery's `file_id`).

**Why OMS's customer hook says `CRM.CUST`.** OMS stores CRM's customer
number, so the order's `hk_customer` uses the CRM key set — and therefore
equals the customer frame's hook value. That shared key set *is* the
integration; no mapping table is involved. If OMS had minted its own customer
numbers, they would get their own key set (`OMS.CUST`) and would *not*
integrate until someone published a key-set mapping. The suite shows this:
an order hooked to `ERP.CUST|C001` is flagged by `v_hook_violation` and does
not resolve to Alice.

---

## The generic loader

`scripts/load_frames.sh` names no entity. It loops over `hook_frame`, reads
each frame's columns from `pragma_table_info`, expects the stage view to
supply each one by the same name, and runs the same three inserts against the
frame's latest row per subject:

1. **Upsert** — write a row if the subject is new, previously deleted, or its
   `diff_str` changed (`INSERT` for new/re-appeared, `UPDATE` otherwise).
2. **Tombstone** — write a `DELETE` row for a live subject. Always honoured.
3. **Absence** — under `FULL` only, write a `DELETE` row for every live
   subject missing from the delivery.

Adding a fifth source table is a `CREATE TABLE frame__…`, a stage view that
adds the hooks, and two registry rows. No new loader code. Because frames are
source-aligned, the load really is the same shape everywhere — which is
HOOK's automation argument, and the thing the hand-written per-entity loaders
in the DV, Kimball and Inmon demos don't have.

---

## The two databases: disposable frames over a durable raw layer

- **`build/hook.db`** — stage, registry, frames, views. **Throwaway.**
- **`archive/hook_archive.db`** — every delivery ever accepted, captured
  *verbatim and before it is applied*, append-only, plus a `loaded_files`
  manifest. **Durable.** `make clean` never touches it.

Frames look a lot like a persistent staging area, so why keep a separate
archive? Because frames are *delta-compressed*: an unchanged restatement
writes nothing, and the stage-L2 dedup throws away the losing duplicate. The
archive keeps what the frames drop, so `make rebuild` can replay every
delivery in its original order through the *same* `apply_delivery.sh` path
that ingested it. The suite asserts the rebuilt frames are identical, down to
each row's `load_ts` and `record_source`.

### How a delivery flows

1. **Stage** the delivery into `stg_*_l1`; record `batch_ts` and `file_id` in
   `hook_load_params`.
2. **Load control** — skip a `file_id` already `COMPLETE`; reject a reused
   `file_id` with a different row count.
3. **Archive** the staged rows verbatim (`INSERT OR IGNORE`, safe to retry).
4. **Apply** via `apply_delivery.sh` → `load_frames.sh`.
5. **Mark COMPLETE**, then clear the stage. A crash leaves the delivery
   `STARTED` with its staged rows in place as forensics.

---

## The read model (views)

| View                      | What it gives you                                                       |
|---------------------------|-------------------------------------------------------------------------|
| `v_latest__<frame>`       | the newest row per subject; a `DELETE` row is a valid latest row        |
| `v_customer` / `v_product`| current, non-deleted subjects — column-for-column with the sibling demos |
| `v_order`                 | current orders; status decoded **on read**; `placed_by` by hook equi-join |
| `v_order_line`            | current order × product pairs                                           |
| `v_order_as_recorded`     | each order row with the customer row that was latest when it loaded     |
| `v_customer_history`      | every customer frame row                                                |
| `v_hook_occurrence`       | every hook value on every frame row                                     |
| `v_concept_member`        | the hub on demand: one row per concept member, with the frames that mention it |
| `v_hook_violation`        | hooks whose key set is unregistered or wrong for their column — must be empty |

Point-in-time is a hook equality plus "latest row at or before this
`load_ts`." No `valid_to` column exists to range-join against, because frames
never close a row.

---

## Make targets

| Target               | Effect                                                                   |
|----------------------|--------------------------------------------------------------------------|
| `make demo`          | fresh archive + schema + the full delivery sequence + printed warehouse  |
| `make rebuild`       | regenerate the frames by replaying the raw layer                         |
| `make test`          | run the test suite (99 assertions)                                       |
| `make init`          | recreate the frame database from schema (the archive survives)           |
| `make clean`         | delete `build/` only — **the archive survives**                          |
| `make clean-archive` | delete `archive/` — destroys the raw layer and the ability to rebuild    |

---

## Repository layout

```
.
├── Makefile
├── HOOK.md                  # design notes: HOOK vs the sibling models
├── schema/
│   ├── 01_stage.sql         # stage L1 tables (shared shape) + L2 views that add the hooks
│   ├── 02_archive.sql       # raw layer: append-only wide history + manifest + triggers
│   ├── 03_hook.sql          # the registry, the four frames, insert-only triggers, ref data
│   └── 04_views.sql         # latest-row, business, as-of, hub-on-demand and integrity views
├── scripts/
│   ├── lib.sh               # shared helpers; the single DB choke point
│   ├── init_db.sh           # (re)create the frame database; preserve the archive
│   ├── load_feed.sh         # ingest ONE delivery (stage → archive → apply → complete)
│   ├── apply_delivery.sh    # the one path from staged rows to frames (ingest AND replay)
│   ├── load_frames.sh       # the generic, registry-driven frame loader
│   ├── rebuild.sh           # ordered replay of the archive
│   └── query.sh             # print the warehouse
├── source/                  # D0–D5, byte-identical with ../v3_datavault and ../v3_inmon-3nf
├── tests/
│   ├── run_tests.sh         # 99 assertions
│   └── fixtures/d6_repoint.sql   # O-101 re-pointed to C001 (data row identical to the siblings')
├── build/                   # generated: the frames (safe to delete)
└── archive/                 # generated: the durable raw layer
```

---

## Testing

```bash
make test
```

**99 assertions**, pure shell + `sqlite3`, covering:

- **Delete semantics** — the stale-window trap, FULL-absence deletes,
  tombstones, recency dedup, load control, and zero-churn idempotence.
- **Hooks** — every hook uses the key set the registry declares (checked
  after every delivery); every `hk_*` column is registered; a wrong key set
  is flagged and does not integrate.
- **Frames** — insert-only (`UPDATE`/`DELETE` abort), delta-compressed
  (fewer rows than the archive), lineage on every row, and no hub, link or
  satellite tables exist.
- **Read model** — current-state views, hub on demand, as-of resolution, and a
  live decode change visible immediately with no reload.
- **The D6 re-point** — one new order row, one current customer, old hook kept
  as history, and a re-sent re-point writes nothing.
- **Rebuild** — `make clean` + replay reproduces the frames exactly.

Mutation-checked: removing the FULL guard, the NOCHANGE guard, the tombstone
branch, or the dead-key guard; reversing the dedup tiebreak or the replay
order; dropping `customer_ref` from the order diff; or reading latest rows
without honouring `DELETE` each turn the suite red.

---

## What HOOK gives up

- **No stored integration point.** There is no hub to tell you "these are all
  the customers." `v_concept_member` derives it by scanning every frame,
  which is cheap here and not free at scale.
- **Integration is only as good as key-set discipline.** Hooks integrate when
  values match exactly. Two systems that identify the same customer
  differently need an explicit key-set mapping — HOOK defers that work; it
  doesn't remove it. This demo has no mapping frame because the corpus doesn't
  need one.
- **Business logic lives entirely in views.** Decodes, current state, and
  point-in-time all run on read. That is what makes a rule change instant and
  history-wide, and it is also where query cost goes.
- **Frames inherit the source's shape.** A source restructure changes the
  frame and every view over it. HOOK accepts that coupling in exchange for
  never translating on the way in.
- **Deletes must be written at load time.** Delta compression means a FULL
  snapshot's absences are only visible while that snapshot is in the stage.

---

## Going deeper

- **[HOOK.md](HOOK.md)** — what HOOK is, where this implementation follows it
  and where the shared discipline fills gaps, and how it compares with the
  sibling models.
- **Sibling demos** — [`../v3_datavault`](../v3_datavault) is the closest
  relative (hooks are DV business keys without the hub);
  [`../v3_one-big-table`](../v3_one-big-table) is the other "keep it raw"
  answer. The [top-level README](../README.md) sets out the full set.
