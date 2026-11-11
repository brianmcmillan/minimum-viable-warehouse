# Data Vault — a Data Vault 2.0 warehouse in SQLite and bash

A small, fully working [Data Vault 2.0](https://en.wikipedia.org/wiki/Data_vault_modeling) warehouse
built from nothing but **`sqlite3`, `bash`, and `make`**. No Python, no dbt, no server, no
dependencies to install. Clone it, run `make demo`, and you have a warehouse that ingests
multi-source feeds, records every attribute change and every presence assertion in insert-only
hubs, satellites and links, handles deletes safely under real feed cadences, and resolves
driving-key relationships (which customer an order belongs to *right now*) correctly when a source
re-points them.

It exists to make the core Data Vault building blocks **executable and testable** in under 900 lines
of shell and SQL, following the DV101 Baseline conventions (source → stage L1 → stage L2 → raw vault
→ business vault → info mart), with three ideas kept front and centre:

- **Insert-only, hard rules only, all the way through.** Nothing in the vault is ever updated or
  deleted. A changed attribute is a *new* satellite row; a delete is a *new* status row. History is a
  side effect of never overwriting anything.
- **Hard rules vs soft rules.** The vault stores exactly what the source sent (raw status code `'P'`);
  the business meaning (`'P' → 'PENDING'`) is applied downstream in the info mart, on read. Change the
  rule and all of history — past and present — reflects it instantly.
- **Presence and effectivity as first-class facts.** "Is this key deleted?" is answered by a
  status-tracking satellite, not inferred. "Which customer does this order belong to now?" is answered
  by an effectivity satellite over an insert-only link that keeps every pairing it ever saw.

> **Part of a nine-model comparison set.** This is the vault leg. The same
> six logical deliveries run through nine warehouses
> ([Inmon 3NF EDW](../v3_inmon-3nf), [Kimball star](../v3_data-marts), this
> Data Vault 2.0, [Focal Point](../v3_focal-point), [Anchor](../v3_anchor),
> [HOOK](../v3_hook), [Unified Star Schema](../v3_unified-star-schema),
> [Activity Schema](../v3_activity-schema), and
> [One Big Table](../v3_one-big-table)), so every difference between them is
> the *model*, never the input. This model takes the wide,
> one-row-per-record restatement shared byte-for-byte by Inmon, Kimball,
> Data Vault, HOOK, USS, Activity Schema and OBT. It is the one model with
> no separate archive: the insert-only raw vault is its history, and the
> delivery files are its only replayable input. **This README stands on its
> own;** [DATAVAULT.md](DATAVAULT.md) draws the cross-model comparison.

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
make demo    # fresh schema + a 6-delivery feed sequence, then print the info mart
make test    # run the full assertion suite (Focal parity + DV-specific behaviours)
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

Those readable rows are *derived* — the vault stores the raw status code `P`, not `PENDING`, and it
stores customers, orders and their relationship in separate insert-only tables. See
[How meaning is stored](#how-meaning-is-stored-the-building-blocks) below.

---

## The core idea in one rule

Real feeds don't resend everything every time. A CRM might send a 14-day change window; a product
catalogue might send a full snapshot; an order system might send a 45-day window. If you treat every
delivery as a full snapshot, then "this record wasn't in the file" wrongly reads as "this record was
deleted" — and a customer who simply hasn't changed in 60 days silently disappears.

This warehouse makes the load strategy explicit per delivery and enforces one rule:

> **Absence means DELETE only for a FULL delivery.**
> An INCREMENTAL (windowed) delivery never infers a delete from absence. Deletes in an incremental
> world must arrive either as an explicit **tombstone** (`op='DELETE'`) or be found later by a
> **FULL reconciliation**.

Every staged row carries `op` (`UPSERT` | `DELETE`) and `load_mode` (`FULL` | `INCREMENTAL`), so a
single delivery declares its own semantics:

```sql
-- source/d0_baseline.sql
INSERT INTO stg_customer_l1(customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode) VALUES
('C001','Alice Smith','alice@example.com','2026-01-05','2026-02-05','UPSERT','FULL'),
('C002','Bob Jones'  ,'bob@example.com'  ,'2026-01-06','2026-02-05','UPSERT','FULL');
```

The satellite loader only turns on the absence-delete branch when the delivery's effective mode is
`FULL`. Same engine, opposite outcomes — driven only by the delivery's declared mode.

### How a delete is *represented*

Because the vault is insert-only, a delete never removes a row. Instead each entity has a
**status-tracking satellite** (`rv_*_sts`) that records presence assertions, change-only:

- `'I'` — the key is (re)inserted at source;
- `'D'` — a tombstone arrived, **or** a FULL delivery omitted the key.

A returning key just writes another `'I'`, so the presence timeline reads `I → D → I` and no history
is ever lost. "Is it deleted?" is the latest `sts` for that key — a first-class fact the info mart
gates on.

### The demo delivery sequence

`make demo` and `make test` run this exact sequence, and each delivery is there to prove one behaviour:

| #  | Delivery                  | Feed / mode                | What it proves                                                       |
|----|---------------------------|----------------------------|---------------------------------------------------------------------|
| B0 | `d0_baseline.sql`         | all / FULL                 | initial full load of every feed                                     |
| D1 | `d1_cust_win_day60.sql`   | CRM.CUSTOMER / INCREMENTAL | a 14-day window updates C001 and **does not** delete stale, absent C002 |
| D2 | `d2_prod_full_v2.sql`     | PIM.PRODUCT / FULL         | absence **does** delete a discontinued SKU (`sts='D'`)              |
| D3 | `d3_cust_tombstone.sql`   | CRM.CUSTOMER / INCREMENTAL | an explicit `op='DELETE'` tombstone deletes C002                    |
| D4 | `d4_cust_recency.sql`     | CRM.CUSTOMER / INCREMENTAL | a repeated attribute resolves to the newest by `extract_dt`         |
| —  | re-send D1                | —                          | a duplicate `file_id` is skipped by load control                    |
| D5 | `d5_cust_yearly_full.sql` | CRM.CUSTOMER / FULL        | a yearly full reconciliation deletes C003, gone at source           |
| D6 | `d6_repoint.sql` *(test)* | OMS.ORDER / INCREMENTAL    | re-pointing O-101 to a new customer flips `placed_by` via effectivity |

---

## How meaning is stored: the building blocks

Every business entity — CUSTOMER, PRODUCT, ORDER — is split across a small set of insert-only table
types. The split is the whole point: keys, descriptive history, presence and relationships each live
in their own table, versioned independently, and nothing is ever overwritten.

| Table type                 | Suffix        | Holds                                                                 |
|----------------------------|---------------|-----------------------------------------------------------------------|
| **hub**                    | `rv_*_h`      | one row per business key, ever — first-seen wins, never updated       |
| **satellite**              | `rv_*_hsat`   | descriptive attributes at whole-row grain, versioned by `ldts`        |
| **status-tracking sat**    | `rv_*_sts`    | presence assertions (`I`/`D`), change-only                            |
| **link**                   | `rv_*_l`      | one row per distinct relationship pair, ever — insert-only            |
| **effectivity satellite**  | `bv_*_effsat` | which pair is *current* for a driving key; end-dates computed on read |

Two design choices keep this small and deterministic:

- **Natural keys, no hashes.** Hubs are keyed on the business key itself. Hash keys are an *optional*
  optimisation in the standard (parallel loading, MPP joins) and buy nothing on single-writer SQLite.
  Change detection still uses the exact string a hash-keyed build would `md5()` — the descriptive
  attributes, trimmed, NULL-coalesced, pipe-delimited — stored in plaintext as `diff_str`. A
  satellite row is written only when its `diff_str` differs from the key's newest one.
- **A deterministic load timestamp.** `ldts` comes from a one-row parameter table (`dv_load_params`)
  set by the driver, not `current_timestamp`, so every run of the demo is byte-for-byte reproducible.

```
                        source deliveries (wide rows, one shape per feed)
                                    │
                     ┌──────────────▼────────────────┐
                     │  stg_*_l1        (stage L1)    │  one wide table per feed
                     │      → v_stg_*_l2 (views)      │  + rsrc / ldts / diff_str, recency-deduped
                     └──────────────┬────────────────┘
                                    │  loaders (load_hubs → load_sats → load_links)
                                    ▼
        ┌────────────────────────────────────────────────┐
        │ rv_*_h   rv_*_hsat   rv_*_sts   rv_*_l   (raw)  │  insert-only raw vault
        │ bv_order_customer_l_effsat          (business)  │  driving-key effectivity
        └──────────────┬─────────────────────────────────┘
                       ▼
        ┌────────────────────────────────────────────────┐
        │ dim_customer / dim_product / fact_order  (mart) │  info mart = the read model
        └────────────────────────────────────────────────┘
```

A hub loads from **every** feed that carries its key, including link ends — `rv_customer_h` fills from
`CRM.CUSTOMER` *and* from the `customer_ref` on `OMS.ORDER` — so a link can never dangle.

---

## Hard rules vs soft rules: raw in, meaning out

The most consequential design decision is *where* business meaning gets applied.

- **Hard rules** (structural, source-faithful) happen on the way *in*: split into hub/sat/link,
  detect change, assert presence. The raw vault stores what the source actually sent. `OMS` delivers
  an order status of `'P'`/`'S'`/`'D'`/`'C'`, and `rv_order_hsat` keeps exactly that, forever.
- **Soft rules** (interpretation) happen on the way *out*, in the info mart. `fact_order` translates
  `'P' → 'PENDING'` in a `CASE` expression at read time.

Because the raw value is never overwritten, changing a soft rule is retroactive with no reload:

```sql
-- schema/05_info_mart.sql — edit the CASE, and every order past and present re-derives instantly
CASE s.status WHEN 'P' THEN 'PENDING' WHEN 'S' THEN 'SHIPPED' ... END AS status
```

`v_order_status_history` prints the raw code beside the translated value so the split is visible:

```
### Order status history (raw beside translated)
order_ref  ldts                 rsrc       raw_status  status
---------  -------------------  ---------  ----------  -------
O-100      2026-02-05 08:00:00  OMS.ORDER  P           PENDING
```

---

## Driving-key effectivity: which customer owns the order *now*

The ORDER→CUSTOMER link has a **driving key**: an order is placed by exactly one customer at a time.
When a delivery re-points an order to a different customer, the insert-only link table simply gains a
second pair — so which one is *current*?

The answer lives in an **insert-only effectivity satellite** (`bv_order_customer_l_effsat`). Each row
opens a pairing for the driving key; end-dates are never written but computed on the way out with
`LEAD` over `start_date`. The newest row per order is the current pairing:

```sql
-- schema/04_business_vault.sql
COALESCE(LEAD(start_date) OVER (PARTITION BY order_bk ORDER BY start_date, ldts),
         '9999-12-31 23:59:59') AS end_date
```

`tests/fixtures/d6_repoint.sql` moves order O-101 from C002 to C001. The link keeps both pairs
(full history), the effectivity satellite makes exactly one current, and `fact_order.placed_by` flips
from `NULL` to `Alice Smith` — with no update and no delete anywhere. (The sibling Focal demo documents
this same scenario as a *known gap* it cannot yet express; here it is a passing test.)

The ORDER→PRODUCT link has no driving key — an order simply contains products — so its pairs are
purely additive and it gets no effectivity satellite.

---

## How a delivery flows

A delivery is a plain `.sql` file that `INSERT`s wide rows into the stage-1 tables (see any file in
[`source/`](source/)). `scripts/load_feed.sh` drives one delivery safely:

1. **Load control** — look up the delivery's `file_id` in `dv_load_audit`. A `file_id` names a
   delivery's *content* (a batch/version id, not a filename — extractors reuse filenames). If it is
   already `COMPLETE`, skip it.
2. **Stage** — clear the stage-1 tables, set `dv_load_params.batch_ts` (the deterministic `ldts`),
   and run the delivery file. Record a `STARTED` audit row (or note a retry of a prior `STARTED`).
3. **Stage 2** — the `v_stg_*_l2` views add `rsrc`/`ldts`/`diff_str` and recency-dedupe within the
   batch (newest by `extract_dt`, `rowid` breaks ties).
4. **Load** — run the three loaders in fixed order: `load_hubs` (keys) → `load_sats` (descriptive
   delta + presence) → `load_links` (pairs + driving-key effectivity). Each branches on the effective
   `FULL`/`INCREMENTAL` mode.
5. **Mark COMPLETE** only after every loader succeeds, then clear the stage. A delivery that crashes
   half-way stays `STARTED`, leaves its staged rows in place as forensics, and is retried on the next
   run — never skipped as done.

De-duplication happens at three levels: the **file** level (a re-sent `file_id` is skipped), the
**row** level (a repeated attribute keeps the newest by `extract_dt`), and the **version** level (an
unchanged fact whose `diff_str` matches the newest satellite row writes nothing).

---

## The info mart (the read model)

Defined in `schema/05_info_mart.sql`, printed by `scripts/query.sh`:

| View                            | What it gives you                                                          |
|---------------------------------|----------------------------------------------------------------------------|
| `dim_customer` / `dim_product`  | current descriptive row per key, gated on the status sat (`sts='I'`)       |
| `fact_order`                    | one order row: soft-rule status translation + `placed_by` via current pairing |
| `v_*_hsat_current`              | the newest satellite row per key                                           |
| `v_*_sts_current`               | the latest presence assertion per key                                      |
| `v_order_status_history`        | the full status timeline, raw code beside translated value                 |
| `v_status_history`              | the presence timeline (`I`/`D`) per key across all three entities          |
| `v_order_customer_eff_history`  | driving-key pairings with computed `end_date` / `iscurrent`                |

A deleted key drops out of `dim_customer`/`dim_product`/`fact_order` because those views inner-join
the status satellite on `sts='I'` — presence is enforced at read time, from a first-class fact.

---

## Make targets

| Target       | Effect                                                                 |
|--------------|------------------------------------------------------------------------|
| `make demo`  | fresh schema + the full delivery sequence + printed info mart          |
| `make test`  | run the full assertion suite                                           |
| `make init`  | recreate the vault database from schema (`build/datavault.db`)         |
| `make clean` | delete `build/` — the vault is fully regenerable from `make demo`      |

There is a **single** database, `build/datavault.db`, and it is disposable: `make clean` throws it
away and `make demo` rebuilds it from the schema and delivery files. The insert-only raw vault is the
durable *history* layer within a run — it preserves every attribute state and every presence
assertion — but note that the delivery files themselves are not archived, so there is no replay of a
past ingest. Natural keys soften the cost: there are no surrogate-key assignments to lose.

---

## Repository layout

```
.
├── Makefile                      # the entry point for every workflow
├── DATAVAULT.md                  # design notes: the side-by-side comparison with the Focal demo
├── schema/
│   ├── 01_stage.sql              # stage L1 tables, load params, load audit
│   ├── 02_stage2_views.sql       # stage L2 views: system columns + diff_str + recency dedup
│   ├── 03_raw_vault.sql          # hubs, satellites, status sats, links
│   ├── 04_business_vault.sql     # insert-only effectivity satellite + LEAD history views
│   └── 05_info_mart.sql          # dim_customer / dim_product / fact_order + audit views
├── scripts/
│   ├── lib.sh                    # shared helpers; the single choke point for DB access + SQL guards
│   ├── init_db.sh                # (re)create the vault database from schema
│   ├── load_feed.sh              # ingest ONE delivery safely (control → stage → load → complete)
│   ├── load_hubs.sh              # hubs: business keys, insert-only, from every feed incl. link ends
│   ├── load_sats.sh              # satellites: whole-row descriptive delta + status tracking
│   ├── load_links.sh             # links: relationship pairs + driving-key effectivity
│   └── query.sh                  # print the info mart + signature audit queries
├── source/                       # the demo delivery files (D0–D5)
├── tests/
│   ├── run_tests.sh              # the assertion suite
│   └── fixtures/d6_repoint.sql   # the driving-key re-point scenario
└── build/                        # generated: the vault database (safe to delete)
```

---

## Testing

```bash
make test
```

One suite, pure shell + `sqlite3`, no external setup. It replays the full delivery sequence against a
fresh database and asserts, among other things:

- **Delete semantics under a realistic cadence** — an incremental window does *not* delete an
  absent-but-unchanged record; a FULL snapshot *does* delete on absence (`sts='D'`); tombstones delete
  in an incremental feed; and a deleted key keeps its hub row and attribute history.
- **Whole-row satellite grain** — one changed attribute writes one new satellite row; an unchanged
  re-delivery (matching `diff_str`) writes nothing.
- **Hard vs soft rules** — the vault keeps the raw `'P'` while the mart derives `PENDING`, and the
  derivation is retroactive with no reload.
- **Driving-key effectivity** — re-pointing an order flips exactly one current pairing while the link
  table keeps both pairs.
- **Load control and idempotence** — a duplicate `file_id` is skipped; replaying the whole sequence
  under new `file_id`s runs every loader but writes zero new rows (a mutation-hardened idempotence
  check that catches, e.g., an effectivity satellite that re-opens an already-current pairing).

The suite prints a per-assertion `PASS`/`FAIL` and exits non-zero if any assertion fails.

---

## Going deeper

- **[DATAVAULT.md](DATAVAULT.md)** — the design notes: how this build maps to the DV101 Baseline
  conventions, where it deliberately deviates (natural keys instead of hashes, insert-only
  effectivity, no ghost/PIT/bridge structures) and why, plus a table-by-table comparison against the
  sibling Focal Point warehouse over the identical six deliveries.
