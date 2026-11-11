# The null hypothesis: One Big Table, no model at all

The no-model position, taken seriously and made to run: the **append-only
delivery log itself is the warehouse**, and everything you query is a
**full-refresh recomputation over that log** — the dbt-style full-refresh /
functional-data-engineering pattern, idempotent by construction, with no
incremental state anywhere. Built from nothing but **`sqlite3`, `bash`, and
`make`**. No Python, no dbt, no server, no packages to install. The
`sqlite3` that ships with macOS is enough.

It exists to answer the question the other eight warehouses in the set raise:
**what does modeling actually buy?** Feed it the same deliveries, get the
same answers — then read the bill.

- **No dimensions, no satellites, no versions.** One denormalized table per
  entity, plus `obt_order_wide` — order-line grain, everything joined flat,
  the table every BI tool wishes it had. All of it recomputed from scratch on
  every load.
- **Delete semantics *derived* from the log, not enforced during it.** A key
  is dead if its latest mention is a tombstone, or if a later FULL snapshot
  of its feed simply omitted it. One query works that out; no load-time state
  machine does.
- **Rebuild is trivial** — `init` plus one refresh — precisely because
  nothing was ever derived incrementally. The modeled demos work hard for
  replay determinism; here it is free.

> **Part of a nine-model comparison set.** This is the null hypothesis. The
> same six logical deliveries run through nine warehouses
> ([Inmon 3NF EDW](../v3_inmon-3nf), [Kimball star](../v3_data-marts),
> [Data Vault 2.0](../v3_datavault), [Focal Point](../v3_focal-point),
> [Anchor](../v3_anchor), [HOOK](../v3_hook),
> [Unified Star Schema](../v3_unified-star-schema),
> [Activity Schema](../v3_activity-schema), and this One Big Table), so
> every difference between them is the *model*, never the input. This model
> takes the wide, one-row-per-record restatement shared byte-for-byte by
> Inmon, Kimball, Data Vault, HOOK, USS, Activity Schema and OBT. Its
> archive uses the same layout (`loaded_files` + per-feed `hist_*` tables,
> append-only triggers) as the Inmon, Kimball, HOOK, USS and Activity Schema
> archives. Keeping the no-model position runnable next to the other eight
> is the cleanest way to price what they add. **This README stands on its
> own;** [OBT.md](OBT.md) draws the cross-model comparison.

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
make demo          # fresh archive + schema + the full 6-delivery sequence, then print the tables
make rebuild       # init + ONE full refresh — no replay loop, nothing incremental
make test          # 55 assertions: derived deletes, the storage bill, history-as-a-query
make clean         # delete build/ only — the archive (the real warehouse) SURVIVES
make clean-archive # delete archive/ — destroys the log, and with it everything
```

`make demo` loads six deliveries standing in for a few weeks of real feeds,
then prints the recomputed latest tables. The namesake table:

```
### obt_order_wide  (order-line grain, everything denormalized)
order_ref  placed_at         status  amount  customer_ref  customer_name  email              sku    product_name  price
---------  ----------------  ------  ------  ------------  -------------  -----------------  -----  ------------  -----
O-100      2026-02-01 10:00  P       29.49   C001          Alice Smith    alice@newmail.com  SKU-1  Widget        8.99
O-100      2026-02-01 10:00  P       29.49   C001          Alice Smith    alice@newmail.com  SKU-2  Gadget        19.5
O-101      2026-02-02 11:30  P       19.5    C002                                            SKU-2  Gadget        19.5
```

Two things are already visible in that output. `O-101` still carries
`customer_ref = C002`, but `customer_name` and `email` are **blank** — C002
was deleted, so the refresh dropped it from `obt_customer`, and the flat join
has nothing to attach. And `SKU-1` shows `8.99` — the *current* price. There
is no version of `Widget @ 9.99` anywhere, even though `O-100` was placed
when that was the price: OBT keeps only latest state, so the point-in-time
answer the [Kimball star](../v3_data-marts) gets from a frozen key simply
does not exist here. Note too that `status` is the raw `'P'` — the
`P → PENDING` decode lives in a view, not in the table (see
[The read model](#the-read-model-views)).

---

## The core idea, in one rule

Real feeds don't resend everything every time. A CRM sends a 14-day change
window; a product catalogue sends a full snapshot; an order system sends a
45-day window. Treat every delivery as a full snapshot and "this record
wasn't in the file" wrongly reads as "this record was deleted" — and a
customer who simply hasn't changed in 60 days silently disappears.

Every warehouse in the set enforces one rule:

> **Absence means DELETE only for a FULL delivery.**
> An INCREMENTAL (windowed) delivery never infers a delete from absence.
> Deletes arrive as an explicit **tombstone** (`op='DELETE'`) or are found
> later by a **FULL reconciliation**.

What makes OBT different is *where* the rule lives. The other eight enforce it
as they load. OBT **derives it from the log** at refresh time, in one query
per feed:

```
latest mention per key : newest row by (load_seq, extract_dt, seq_nbr)
deleted                : latest mention is a tombstone, OR any FULL delivery
                         of the feed arrived after it — because had the key
                         been in that snapshot, THAT would be the latest
                         mention. So a later FULL that omits the key means
                         absence, exactly the shared rule, read back out of
                         the log instead of enforced into it.
latest values          : the newest UPSERT mention
```

Every staged row still declares its `op` and `load_mode`; the difference is
that nothing acts on them at load time — they are just archived, and
`refresh_latest.sh` reads them all at once.

### The demo delivery sequence

`make demo` and `make test` run this exact sequence; each delivery earns its
place by proving one behaviour:

| #  | Delivery                  | Feed / mode                | What it proves                                                                    |
|----|---------------------------|----------------------------|-----------------------------------------------------------------------------------|
| D0 | `d0_baseline.sql`         | all / FULL                 | initial full load of every feed                                                   |
| D1 | `d1_cust_win_day60.sql`   | CRM.CUSTOMER / INCREMENTAL | a 14-day window updates C001 and **does not** delete stale, absent C002           |
| D2 | `d2_prod_full_v2.sql`     | PIM.PRODUCT / FULL         | absence **does** delete a discontinued SKU — derived from the later FULL          |
| D3 | `d3_cust_tombstone.sql`   | CRM.CUSTOMER / INCREMENTAL | an explicit `op='DELETE'` tombstone deletes C002 in an incremental feed           |
| D4 | `d4_cust_recency.sql`     | CRM.CUSTOMER / INCREMENTAL | adds C003; a repeated attribute resolves to the newest by `extract_dt`            |
| —  | re-send D1                | (same `file_id`)           | load control skips a duplicate delivery (exercised by `make test`)                |
| D5 | `d5_cust_yearly_full.sql` | CRM.CUSTOMER / FULL        | a yearly full reconciliation deletes C003, gone at source                         |

Same corpus, same end state, as every sibling: C001 alive at
`alice@newmail.com`, C002 and C003 deleted, SKU-3 discontinued, SKU-1 at
`8.99`.

---

## How the "model" is shaped — the log, and one transform

There is no schema to draw. There is a log, and there is a query that folds
it into latest state.

**The log** (`schema/02_archive.sql`) is one wide `hist_*` table per feed,
plus the `loaded_files` manifest. Append-only, verbatim, pre-dedup — the same
capture discipline every sibling uses, except here the log is not a safety
layer *behind* the warehouse, it **is** the warehouse.

**The latest tables** (`schema/01_stage.sql`) are pure derived output,
fully recomputed on every load:

| Table             | Holds                                                                            |
|-------------------|----------------------------------------------------------------------------------|
| `obt_customer`    | one row per live customer — latest UPSERT values                                 |
| `obt_product`     | one row per live SKU                                                             |
| `obt_orders`      | one row per live order; `status` is the **raw** source code, decoded on read     |
| `obt_order_lines` | order × product pairs                                                            |
| `obt_order_wide`  | the **One Big Table**: order-line grain, customers and products joined in flat   |

**The transform** (`scripts/refresh_latest.sh`) is the entire model layer.
For each feed it ranks every mention of every key, decides alive-or-dead by
the derived delete rule, takes the newest UPSERT values for the survivors,
and finally denormalizes orders × lines × customers × products into
`obt_order_wide`. Read the length of that file as *data*, not accident: this
is the complexity every warehouse carries. The others pay it once, at load
time, and bank the result. OBT pays it on every refresh — and every consumer
who bypasses these tables and queries the log directly pays it again.

```
        source deliveries ──▶ stg_*_l1 ──▶ append to hist_* (THE warehouse)
                                                   │
                                                   ▼
                                        refresh_latest.sh
                                   (full recomputation, every load)
                                                   │
                                                   ▼
                        obt_customer / obt_product / obt_orders /
                        obt_order_lines / obt_order_wide  (derived, disposable)
```

---

## The two databases: disposable latest tables over the log that is the warehouse

The usual split in this set is "disposable derived layer over a durable raw
layer." OBT has the same two files — but here the durable one *is* the
product, not a backup of it.

- **`build/obt.db`** — the recomputed latest tables (and the stage surface).
  **Throwaway**, and cheaply so: they are a pure function of the log.
- **`archive/obt_archive.db`** — the append-only log. **The warehouse
  itself.** Everything true is in here; the latest tables are just a
  convenient projection. It lives outside `build/` so that `make clean`
  cannot touch it.

Which is why rebuild needs no replay loop:

```bash
make rebuild   # init + ONE full refresh; there is no incremental state to reconstruct
```

The other archive-backed demos replay every delivery in order through their
real loaders to prove fidelity. OBT can't get replay wrong, because it never
derived anything incrementally in the first place — `rebuild` is `init`
followed by a single `refresh_latest.sh`. That triviality is the pattern's
rhetorical payoff; the cost simply lives elsewhere (see below). Nothing can
delete a logged row: the append-only triggers in `schema/02_archive.sql` have
no unlock path.

---

## How a delivery flows

A delivery is a plain `.sql` file that inserts rows into the `stg_*_l1` stage
tables (see any file in [`source/`](source/)). `scripts/load_feed.sh` is ELT
at its most literal — stage, append, refresh, with no merge or delta engine
anywhere:

1. **Stage** the delivery into `stg_*_l1`.
2. **Load control** — look up the delivery's `file_id`. A `file_id` names a
   delivery's *content* (a batch/version id, not a filename). If it is
   already `COMPLETE`, skip it. If the same `file_id` reappears with a
   *different* row count, reject it loudly.
3. **Append** the staged rows verbatim into the append-only `hist_*` log —
   idempotent (`INSERT OR IGNORE` never fires the append-only triggers), so a
   retry is safe.
4. **Refresh** — run `refresh_latest.sh`, which throws away every latest
   table and recomputes it from the whole log.
5. **Mark COMPLETE** only after the refresh succeeds, then clear the stage.

Load control is the one piece of shared discipline OBT keeps in full: a
re-sent `file_id` is skipped and a mismatched one is rejected. What it
deliberately does *not* have is any row- or version-level suppression — see
the storage bill below.

---

## What it gets right, embarrassingly cheaply

- **Every shared scenario passes.** The stale-window trap, tombstones, FULL
  reconciliation, recency dedup, even the D6 re-point (latest simply wins) —
  all computed by one query per feed in
  [`refresh_latest.sh`](scripts/refresh_latest.sh).
- **Rebuild is trivial** — `init` plus one refresh — because nothing was ever
  derived incrementally.
- **`obt_order_wide` is the table BI tools want**: order-line grain,
  everything denormalized, no joins to reason about at query time.

## Where the bill arrives, asserted by tests

1. **No NOCHANGE concept.** D2's unchanged SKU-2 is stored again in full; a
   re-delivered snapshot under a new `file_id` grows the log while changing
   nothing. Every sibling suppresses this — OBT's storage grows with
   **deliveries**, not with **change**.
2. **History is a query, not a table.** C001's email timeline is recoverable
   — via `LAG` over the log with the correct three-column ordering — and the
   suite proves it. But every history question is that query, written again,
   by every consumer, correctly, every time. Deleted Bob survives *only* in
   the log; nothing keeps him queryable.
3. **Semantics live in views, or nowhere.** The `P → PENDING` rule is a
   `CASE` in `v_order`. Anyone who queries `obt_orders` (or `obt_order_wide`)
   directly gets the raw code. There is no model layer to state the rule once.
4. **The transform's complexity is data.** `refresh_latest.sh` re-derives, on
   *every load*, what the others compute once per delivery. At six deliveries
   that is invisible; at thousands, the full refresh *is* the nightly batch
   window.

---

## The read model (views)

Defined in `schema/01_stage.sql`, printed by `scripts/query.sh`:

| View          | What it gives you                                                                 |
|---------------|-----------------------------------------------------------------------------------|
| `v_customer`  | one row per live customer                                                          |
| `v_product`   | one row per live SKU                                                              |
| `v_order`     | one row per live order, with the **`P → PENDING` decode applied** and `placed_by` resolved against the current customer |

`v_customer` / `v_product` / `v_order` mirror the sibling demos' business
views column-for-column, so `make demo` outputs compare directly across
models. The decode living in `v_order` rather than in `obt_orders` is the
point of finding #3 above: the view is the *only* place the business rule
exists.

---

## Make targets

| Target               | Effect                                                                                     |
|----------------------|--------------------------------------------------------------------------------------------|
| `make demo`          | fresh archive + schema + the full delivery sequence + printed tables                       |
| `make rebuild`       | `init` + ONE full refresh (no replay loop needed)                                          |
| `make test`          | run the OBT test suite (55 assertions)                                                      |
| `make init`          | recreate the latest tables from schema (the archive survives)                              |
| `make clean`         | delete `build/` only — **the archive, the real warehouse, survives**; `make rebuild` restores the tables |
| `make clean-archive` | delete `archive/` — destroys the log and therefore everything (deliberately separate from `clean`) |

`make demo` rebuilds a fresh archive first, because deliveries are skipped
once `COMPLETE`; it is the only target that discards the log implicitly.

---

## Repository layout

```
.
├── Makefile                 # the entry point for every workflow
├── OBT.md                   # design notes: the null hypothesis vs the sibling models, in depth
├── schema/
│   ├── 01_stage.sql         # the file-ingest stage + the derived latest tables + business views
│   └── 02_archive.sql       # THE warehouse: append-only wide log + manifest + triggers
├── scripts/
│   ├── lib.sh               # shared helpers; the DB choke points + SQL-injection guards
│   ├── init_db.sh           # (re)create the latest tables; preserve the log
│   ├── load_feed.sh         # ingest ONE delivery (stage → append → refresh → complete)
│   ├── refresh_latest.sh    # THE transform: full recomputation of latest state over the log
│   ├── rebuild.sh           # init + one refresh (no replay loop)
│   └── query.sh             # print the latest tables + the pattern's signature exhibits
├── source/                  # the demo delivery files (D0–D5), byte-identical with ../v3_datavault
├── tests/
│   ├── run_tests.sh         # 55-assertion suite (derived deletes, the storage bill, history-as-a-query)
│   └── fixtures/
│       └── d6_repoint.sql   # restatement fixture: latest wins here
├── build/                   # generated: the latest tables (safe to delete)
└── archive/                 # generated: the log — the actual warehouse (do NOT delete lightly)
```

---

## Testing

```bash
make test
```

One suite, pure shell + `sqlite3`, **55 assertions**, mutation-hardened (the
mode-filter, ranking-order, and skipped-refresh mutations were all verified to
fail it). It replays the shared delivery scenario against the latest tables
and then exercises the OBT-specific behaviours:

- **Delete semantics *derived* from the log** — an incremental window does
  *not* delete an absent-but-unchanged record; a later FULL snapshot *does*
  delete on absence; tombstones delete; recency de-duplication picks the
  newest mention; and load control (skip a re-sent `file_id`, retry a crashed
  one).
- **The storage bill** — an unchanged SKU is stored again; a re-delivered
  snapshot grows the log without changing an answer.
- **History-as-a-query** — the `LAG`-over-the-log email timeline reconstructs
  correctly under the three-column ordering.
- **Rebuild triviality** — `init` + one refresh reproduces the latest tables
  exactly, with no replay loop.

The suite passes with no external setup.

---

## Honest scorecard vs the other eight

Same input, same answers, so the trade is stark. OBT **wins** on loader
simplicity, rebuild triviality, and time-to-first-query. It **loses** on
storage growth, history access, single-statement semantics, and refresh cost
at scale. Every one of those losses is exactly the line item some model in
this repo exists to fix:

- point-in-time you can't get → the [Kimball star](../v3_data-marts)'s frozen
  keys;
- history as a table, not a query → Data Vault's insert-only satellites, the
  Inmon EDW's time-variant rows;
- storage that grows with change, not deliveries → every sibling's NOCHANGE
  suppression;
- semantics stated once → any of the modeled layers.

That is the whole reason to keep the null hypothesis runnable next to them.

---

## Going deeper

- **[OBT.md](OBT.md)** — the design notes: what the no-model position gets
  right embarrassingly cheaply, where the bill arrives, and the honest
  scorecard against the other eight. Draws the full comparison across the
  model set.
- **Sibling demos** — [`../v3_data-marts`](../v3_data-marts) (Kimball star)
  and [`../v3_inmon-3nf`](../v3_inmon-3nf) (the 3NF control group) ingest the
  *same deliveries* and reach the *same end state* — the sharpest way to see
  what a model buys. The [top-level README](../README.md) sets out all nine
  warehouses and the essays that argue over how to choose between them.
