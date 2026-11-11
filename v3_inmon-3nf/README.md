# The control group: a time-variant 3NF EDW

Inmon's enterprise data warehouse, rendered the classic way and made to
run — a **subject-oriented, integrated, time-variant, non-volatile**
normalized core, built from nothing but **`sqlite3`, `bash`, and `make`**.
No Python, no dbt, no server, no packages to install. The `sqlite3` that
ships with macOS is enough. Clone it, run `make demo`, and you have a 3NF
warehouse that ingests multi-source feeds, versions every entity in place
with `valid_from`/`valid_to`, handles deletes safely under realistic feed
cadences — and can delete its whole EDW and rebuild it from a durable,
append-only raw layer.

This is the leg every other model in the set reacts to, so its job is to be
**honest in both directions**: better than its "current-state-only"
reputation, and unsparing about the two costs its successors exist to fix.

- **Natural keys, no surrogate machinery.** `customer_ref` *is* the key;
  `orders.customer_ref` is a plain foreign-key column. The relationship is
  third normal form and nothing more — no hubs, no anchors, no ties, no
  rowid surrogates.
- **Time-variant rows.** Every entity table carries `valid_from`/`valid_to`.
  A change *closes* the current row (an `UPDATE`) and inserts a new one, so
  current state and full history live in the **same table**.
- **Integrated = conformed on the way in.** The EDW stores `PENDING`, never
  the raw `'P'`. Cleansing happens at ingest through a normalized reference
  table; the raw code survives only in the archive — which is what makes the
  conformance rule retroactively fixable by `make rebuild`.

> **Part of a nine-model comparison set.** This is the control group. The
> same six logical deliveries run through nine warehouses (this Inmon 3NF
> EDW, [Kimball star](../v3_data-marts), [Data Vault 2.0](../v3_datavault),
> [Focal Point](../v3_focal-point), [Anchor](../v3_anchor),
> [HOOK](../v3_hook), [Unified Star Schema](../v3_unified-star-schema),
> [Activity Schema](../v3_activity-schema), and
> [One Big Table](../v3_one-big-table)), so every difference between them is
> the *model*, never the input. This model takes the wide,
> one-row-per-record restatement shared byte-for-byte by Inmon, Kimball,
> Data Vault, HOOK, USS, Activity Schema and OBT. Its archive uses the same
> layout (`loaded_files` + per-feed `hist_*` tables, append-only triggers)
> as the Kimball, HOOK, USS, Activity Schema and OBT archives. In the
> classic CIF picture, the [Kimball star](../v3_data-marts) downstream is
> exactly the kind of departmental mart this EDW would feed. **This README
> stands on its own;** [INMON.md](INMON.md) draws the cross-model
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
make demo          # fresh archive + schema + the full 6-delivery sequence, then print the EDW
make rebuild       # delete the EDW; replay the raw layer to rebuild it
make test          # 64 assertions: delete semantics, time-variance, range-join PIT, exact rebuild
make clean         # delete build/ only — the archive SURVIVES
make clean-archive # delete archive/ — destroys the raw layer, and the ability to rebuild
```

`make demo` loads six deliveries standing in for a few weeks of real feeds,
then prints the business views. Two of them, side by side, are the whole
point of this demo:

```
### Orders                                   (v_order: joins the CURRENT customer)
order_ref  status   amount  currency  placed_at         placed_by
---------  -------  ------  --------  ----------------  -----------
O-100      PENDING  29.49   USD       2026-02-01 10:00  Alice Smith
O-101      PENDING  19.5    USD       2026-02-02 11:30

### Orders as recorded                       (v_order_as_recorded: a RANGE join)
order_ref  recorded_at          status   amount  placed_by_as_recorded
---------  -------------------  -------  ------  ---------------------
O-100      2026-02-05 08:00:00  PENDING  29.49   Alice Smith
O-101      2026-02-05 08:00:00  PENDING  19.5    Bob Jones
```

Look at `O-101`. In `v_order`, `placed_by` is **blank** — it was placed by
C002, since deleted, and the view follows the *current* world. To recover
*who placed it at the time* you must drop to `v_order_as_recorded`, whose
`placed_by_as_recorded` is **Bob Jones**, resolved by a **range join**
against the customer's validity window (`o.valid_from >= c.valid_from AND <
c.valid_to`). That BETWEEN predicate is the tax the 3NF model pays — and
precisely what Kimball's frozen surrogate key, Data Vault's satellites, and
Anchor's latest-views all exist to turn back into an equi-join.

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
is shared across every model in the set; the EDW's mechanism is the classic
close-and-insert:

| event | Inmon 3NF (this demo) | Kimball | Data Vault |
|---|---|---|---|
| attribute change | **close the current row (UPDATE `valid_to`) + insert a new version** | expire dim row + new SCD2 version | new `_hsat` row |
| delete detected | **close + `is_deleted` marker version** carrying last-known attributes | expire + deleted-marker version | `'D'` status satellite |
| unchanged re-delivery | **`diff_str` match — writes nothing** | `diff_str` match, writes nothing | hashdiff match, writes nothing |
| point-in-time | **RANGE join on the validity window** | frozen surrogate key (equi-join) | satellite as-of query |

### The demo delivery sequence

`make demo` and `make test` run this exact sequence; each delivery earns its
place by proving one behaviour:

| #  | Delivery                  | Feed / mode                | What it proves                                                                    |
|----|---------------------------|----------------------------|-----------------------------------------------------------------------------------|
| D0 | `d0_baseline.sql`         | all / FULL                 | initial full load of every feed                                                   |
| D1 | `d1_cust_win_day60.sql`   | CRM.CUSTOMER / INCREMENTAL | a 14-day window versions C001 and **does not** delete stale, absent C002          |
| D2 | `d2_prod_full_v2.sql`     | PIM.PRODUCT / FULL         | absence **does** delete a discontinued SKU (as an `is_deleted` marker version)    |
| D3 | `d3_cust_tombstone.sql`   | CRM.CUSTOMER / INCREMENTAL | an explicit `op='DELETE'` tombstone deletes C002 in an incremental feed           |
| D4 | `d4_cust_recency.sql`     | CRM.CUSTOMER / INCREMENTAL | adds C003; a repeated attribute resolves to the newest by `extract_dt`            |
| —  | re-send D1                | (same `file_id`)           | load control skips a duplicate delivery (exercised by `make test`)                |
| D5 | `d5_cust_yearly_full.sql` | CRM.CUSTOMER / FULL        | a yearly full reconciliation deletes C003, gone at source                         |

---

## How the EDW is shaped

Third normal form, subject by subject. Every entity table holds current and
historical rows together, keyed by its natural business key plus
`valid_from`.

| Table              | Kind                         | Holds                                                                              |
|--------------------|------------------------------|------------------------------------------------------------------------------------|
| `customer`         | time-variant entity          | one row per *version*; PK `(customer_ref, valid_from)`, `is_current` / `is_deleted` |
| `product`          | time-variant entity          | one row per version of a SKU, same shape                                            |
| `orders`           | time-variant entity          | one row per order version; `customer_ref` is a plain natural-key FK; `status` is **conformed** (`PENDING`, not `'P'`) |
| `order_line`       | static association           | order × product pairs, insert-if-absent                                            |
| `order_status_ref` | normalized reference         | the conformance rule (`P → PENDING`), applied at ingest; unmapped codes stored as `UNKNOWN(<code>)`, flagged not rejected |

`diff_str` is the loader's change-compare string (the concatenated, trimmed
*raw* source attributes). Comparing an incoming row's `diff_str` against the
current version's stored one is the whole change-detection mechanism — kept
in plaintext here so it stays legible.

Conformance tolerance is a deliberate design choice, not sloppiness: an
unknown status code lands as `UNKNOWN(C)` rather than failing the load, the
classic EDW-cleansing posture — the exact opposite of Anchor's closed knots,
which reject an unknown member outright. Same corpus, opposite philosophy.

```
                     source deliveries (op / load_mode rows)
                                   │
                    ┌──────────────▼───────────────┐
                    │  stg_*_l1        (stage L1)   │  one wide table per feed
                    │      → v_stg_*_l2 (views)     │  recency-dedup + diff_str
                    └──────────────┬───────────────┘
                                   │  load_edw (close → insert → markers)
                                   ▼
                    ┌──────────────────────────────┐
                    │  customer  product  orders   │  the time-variant 3NF core
                    │  order_line  order_status_ref │  (natural keys, validity windows)
                    └──────────────┬───────────────┘
                                   ▼
                    ┌──────────────────────────────┐
                    │  v_customer / v_product /     │  business views (current state)
                    │  v_order / v_order_as_recorded │  + the range-join PIT view
                    └──────────────────────────────┘
```

---

## The two databases: a disposable EDW over a durable raw layer

There are **two** SQLite files, and the split between them is what turns a
classic CIF weakness into a strength.

- **`build/edw.db`** — the time-variant 3NF core. Everything you query.
  **Throwaway.**
- **`archive/edw_archive.db`** — the **raw layer**. Every delivery ever
  accepted, captured *verbatim and before it is applied*, append-only, plus
  a `loaded_files` manifest of what arrived and in what order. **Durable.**
  It lives outside `build/` so that `make clean` and re-initialisation
  cannot touch it.

Classic Inmon CIF had no such layer of its own: to re-conform history you
re-extracted from sources, or restored from backup. The archive is this
demo's one deliberate modernisation, and it is shared, byte-for-byte, with
every sibling model. Because the raw input is never destroyed, the EDW is
disposable:

```bash
make rebuild   # drop build/edw.db and replay the archive through the SAME loaders
```

`rebuild` replays every archived delivery, in original ingest order, through
the *same* code path that ingested it — `scripts/apply_delivery.sh` is shared
by ingest and replay. (If replay had its own path, a green rebuild would
prove nothing about ingest.) That buys two things a backup never could:

- **Fix an ETL bug.** Correct the loader and run `make rebuild`. There is no
  "restore from backup," because the raw input was never overwritten.
- **Re-conform history retroactively.** `order_status_ref` maps `'P' → 'PENDING'`
  at ingest, but the raw `'P'` survives in the archive. Edit the seed, run
  `make rebuild`, and the whole history re-derives under the new rule — the
  recourse classic CIF never had. The suite asserts both the one-way door
  (stored rows keep the old label until a rebuild) and the escape hatch.

Natural keys make rebuild fidelity trivial to reason about — there are no
surrogate keys to reproduce — but the ordering guarantees still decide the
recency tiebreak (deliveries replay in `load_seq` order, rows restore in
`seq_nbr` order), so they still carry regression tests. Nothing in the
project can delete an archived row: the append-only triggers in
`schema/02_archive.sql` have no unlock path.

---

## How a delivery flows

A delivery is a plain `.sql` file that inserts rows into the `stg_*_l1` stage
tables (see any file in [`source/`](source/)). `scripts/load_feed.sh` drives
one delivery safely, capturing the raw input *before* applying it:

1. **Stage** the delivery into `stg_*_l1`, and record its logical timestamp
   in `edw_load_params`.
2. **Load control** — look up the delivery's `file_id`. A `file_id` names a
   delivery's *content* (a batch/version id, not a filename — extractors
   reuse filenames). If it is already `COMPLETE`, skip it. If the same
   `file_id` reappears with a *different* row count, reject it loudly rather
   than let the archive stop describing what was actually applied.
3. **Archive** the staged rows verbatim into the append-only `hist_*` tables
   — idempotent (`INSERT OR IGNORE` never fires the append-only triggers, so
   retries are safe), assigning `load_seq` on first sight.
4. **Apply** via `apply_delivery.sh` → `load_edw.sh`, the single merge
   loader: per entity, **close** the version-worthy current rows (changed
   upsert, resurrection, tombstone always, FULL absence only), **insert** new
   current versions, then **insert** `is_deleted` markers. All conformance
   (`P → PENDING`) happens here.
5. **Mark COMPLETE** only after the loader succeeds, then clear the stage. A
   delivery that crashes half-way stays `STARTED`, leaves its staged rows as
   forensics, and is retried on the next run — never skipped as done.

De-duplication happens at three levels: the **file** level (a re-sent
`file_id` is skipped), the **row** level (a repeated attribute keeps the
newest by `extract_dt` in the `v_stg_*_l2` views), and the **version** level
(an unchanged entity matches `diff_str` and writes nothing).

---

## What the control group demonstrates (both directions)

The point of keeping Inmon runnable next to its successors is to stop
strawmanning it. The suite proves it holds up, then shows exactly where it
hurts.

**Where it holds up better than its reputation.** A *time-variant* 3NF core
handles the entire shared scenario correctly: the stale-window trap, the
tombstone, the FULL reconciliation, zero-churn re-deliveries — even the D6
re-point, which simply **versions the order row**, keeping the old
customer pairing as queryable history (where Kimball, by contrast, `UPDATE`s
the fact in place). Inmon's EDW was never the "current-state-only" database
its critics assume.

**Where the pain lives, made visible by tests:**

1. **Queries follow the current world.** `v_order` joins `customer` by
   natural key, so `placed_by` always shows the *current* name — and turns
   `NULL` the moment C002 is deleted. Point-in-time needs the **range join**
   in `v_order_as_recorded`, the BETWEEN gymnastics every successor model
   exists to avoid.
2. **Conformance at ingest is a one-way door — without the archive.** The
   suite changes `order_status_ref` live and proves stored rows keep the old
   label. Classic CIF stopped there. The shared raw layer is the escape
   hatch, and it is asserted: edit the seed, `make rebuild`, history
   re-derives.
3. **Schema evolution is `ALTER TABLE` on populated history tables** —
   stated, not tested, because there is no non-destructive path here. This is
   the single strongest argument each successor model makes against this one.

---

## The read model (views)

Defined in `schema/03_edw.sql`, printed by `scripts/query.sh`:

| View                  | What it gives you                                                                 |
|-----------------------|-----------------------------------------------------------------------------------|
| `v_customer` / `v_product` | one readable row per current, non-deleted entity                             |
| `v_order`             | one row per current order, `placed_by` resolved against the **current** customer  |
| `v_order_as_recorded` | the point-in-time view: a **range join** to the customer version valid when the order was recorded |
| `v_customer_history`  | every version of every customer, with its validity window                         |

`v_customer` / `v_product` / `v_order` mirror the sibling demos' business
views column-for-column, so `make demo` outputs compare directly across
models.

---

## Make targets

| Target               | Effect                                                                                  |
|----------------------|-----------------------------------------------------------------------------------------|
| `make demo`          | fresh archive + schema + the full delivery sequence + printed EDW                       |
| `make rebuild`       | regenerate the EDW by replaying the raw layer                                            |
| `make test`          | run the EDW test suite (64 assertions)                                                   |
| `make init`          | recreate the EDW from schema (the archive survives)                                      |
| `make clean`         | delete `build/` only — **the archive survives**; `make rebuild` restores the EDW        |
| `make clean-archive` | delete `archive/` — destroys the raw layer and the ability to rebuild (deliberately separate from `clean`) |

`make demo` rebuilds a fresh archive first, because deliveries are skipped
once `COMPLETE`; it is the only target that discards the archive implicitly.

---

## Repository layout

```
.
├── Makefile                 # the entry point for every workflow
├── INMON.md                 # design notes: the control group vs the sibling models, in depth
├── schema/
│   ├── 01_stage.sql         # stage L1 tables (shared shape) + L2 dedup / diff_str views
│   ├── 02_archive.sql       # raw layer: append-only wide history + manifest + triggers
│   └── 03_edw.sql           # time-variant 3NF entities, order_status_ref, business + PIT views
├── scripts/
│   ├── lib.sh               # shared helpers; the single DB choke point + SQL-injection guards
│   ├── init_db.sh           # (re)create the EDW; preserve the archive
│   ├── load_feed.sh         # ingest ONE delivery safely (stage → archive → apply → complete)
│   ├── apply_delivery.sh    # the one path from staged rows to the EDW (ingest AND replay)
│   ├── load_edw.sh          # the single merge loader: close → insert → is_deleted markers
│   ├── rebuild.sh           # ordered replay of the archive to regenerate the EDW
│   └── query.sh             # print the EDW + its signature queries
├── source/                  # the demo delivery files (D0–D5), byte-identical with ../v3_datavault
├── tests/
│   ├── run_tests.sh         # 64-assertion suite (delete semantics, time-variance, range-join PIT, exact rebuild)
│   └── fixtures/
│       └── d6_repoint.sql   # restatement fixture: the re-point that becomes an order VERSION here
├── build/                   # generated: the EDW (safe to delete)
└── archive/                 # generated: the durable raw layer (do NOT delete lightly)
```

---

## Testing

```bash
make test
```

One suite, pure shell + `sqlite3`, **64 assertions**, mutation-hardened (the
FULL-guard, replay-order, and churn-guard mutations were all verified to fail
it). It replays the shared delivery scenario against the EDW and then
exercises the Inmon-specific behaviours:

- **Delete semantics under a realistic cadence** — an incremental window does
  *not* delete an absent-but-unchanged record; a FULL snapshot *does* delete
  on absence (as an `is_deleted` marker carrying last-known attributes);
  tombstones delete in an incremental feed; recency de-duplication; and load
  control (skip a re-sent `file_id`, retry a crashed one).
- **Time-variance** — version counts, exactly one current row per key,
  validity windows closed at the batch timestamp, and the D6 re-point
  versioning the order while the prior pairing stays queryable.
- **Point-in-time via the range join** — `v_order_as_recorded` resolves the
  customer version valid when the order was recorded, and `v_order` follows
  the current world.
- **Conformance at ingest** — the EDW stores `PENDING`; a live change to
  `order_status_ref` leaves stored rows on the old label until a rebuild
  re-derives them.
- **The archive guarantees** — append-only is absolute, and `make clean` +
  `make rebuild` reproduces the EDW *exactly*, validity windows included.

The suite passes with no external setup.

---

## What the EDW gives up (and where the successors win)

The 3NF EDW is a set of deliberate trade-offs, and the demo keeps them honest
rather than hiding them:

- **Point-in-time is a range join, not an equi-join.** Every as-of question
  needs the `valid_from`/`valid_to` BETWEEN predicate. Kimball's frozen
  surrogate key, DV's satellites, and Anchor's latest-views all exist to
  replace it with a plain join.
- **Current-state queries lose deleted context.** `v_order.placed_by` goes
  `NULL` when the customer is deleted; recovering the name means the recorded
  view, not the business view.
- **Schema evolution is DDL on populated history.** A new attribute means
  `ALTER TABLE` on tables that already hold every version — where a
  metadata-driven model would add a row.
- **Conformance is baked in at ingest.** The EDW stores the cleansed value;
  only the archive keeps the raw code, and only `make rebuild` re-conforms.

---

## Going deeper

- **[INMON.md](INMON.md)** — the design notes: what "classic" means here,
  where the control group holds up and where the pain lives, and how the raw
  layer is the one shared modernisation. Draws the full comparison across the
  model set.
- **Sibling demos** — the [Kimball star](../v3_data-marts) is the
  departmental mart this EDW would feed in the CIF picture;
  [`../v3_datavault`](../v3_datavault) (Data Vault 2.0) and
  [`../v3_one-big-table`](../v3_one-big-table) (the null hypothesis) ingest
  the *same deliveries* and reach the *same end state*. The
  [top-level README](../README.md) sets out all nine warehouses and the essays
  that argue over how to choose between them.
