# Data Vault 2.0 variant — same deliveries, different model

A parallel implementation of the `v3_focal-point` (Focal Point)
demo as a Data Vault 2.0 warehouse: native SQLite, bash, Makefile, no other
dependencies. The **same six logical deliveries** flow through both models,
and the test suites assert the same outcomes — so every difference you see
is the model, not the data.

```bash
make demo   # baseline + 5 deliveries + info mart
make test   # 77 assertions: the Focal scenarios + DV-specific behaviours
```

Structure follows the DV101 Baseline conventions (source → stage L1 →
stage L2 → raw vault → business vault → info mart; `rv_*_h` / `_hsat` /
`_l`, `rsrc` + `ldts` on every row, insert-only throughout). The code is
original; the training package's SQL is © DataVaultAlliance and only its
*patterns* are reproduced here.

## The same core rule, a different mechanism

> **Absence means DELETE only for a FULL delivery.** An INCREMENTAL
> delivery never infers a delete from absence — deletes arrive as explicit
> tombstones (`op='DELETE'`) or are found by a FULL reconciliation.

Both demos enforce this identically. What differs is the *representation*:

| event | Focal | Data Vault |
|---|---|---|
| delete detected | closing version row, `row_st='N'`, per atomic context | one `'D'` row in a **status-tracking satellite** |
| record returns | delta engine reopens (`NEW`) | one `'I'` row; timeline reads I→D→I |
| attribute history | kept in `_desc` versions | kept in `_hsat` — deletes never touch it |
| "is it deleted?" | inferred from descriptor state (its known entity-status gap) | first-class: latest `sts` per key |

## Deviations from the training package, and why

- **Natural keys, no hashes.** Hubs are keyed on the business key itself.
  Hash keys are an *optional* optimisation in the standard (parallel
  loading, MPP joins) and buy nothing on single-writer SQLite. `diff_str`
  in each satellite is exactly the string the training views feed into
  `md5(...)` — pipe-delimited, trimmed, NULL-coalesced — stored in
  plaintext. The change-detection semantics are identical.
- **Stage 2 stays views** (as in the training package) precisely *because*
  there is no hashing: everything they compute is native SQLite. `ldts`
  comes from a one-row parameter table instead of `current_timestamp` so
  every run is deterministic.
- **No schemas in SQLite** — prefixes (`stg_`, `rv_`, `bv_`, `dim_`/`fact_`)
  stand in for `baseline_stage` / `baseline_vault`.
- **Effectivity satellite is the insert-only variant** ("no end-date,
  100% insert driven"): end dates are computed with `LEAD` on the way out,
  never written. The upsert-style effsat with stored `end_date`/`iscurrent`
  was deliberately not used — it breaks insert-only purity.
- **Scope**: hubs, sats, status sats, links, one effectivity sat, info
  mart. Ghost records, PIT/bridge, same-as links and multi-active sats are
  omitted — the shared sample data has no scenario for them.

## What the vault demonstrates that Focal (currently) cannot

1. **Driving-key effectivity.** `tests/fixtures/d6_repoint.sql` re-points
   order O-101 from C002 to C001. The link table keeps both pairs
   (insert-only history); the effectivity satellite makes exactly one
   current — `placed_by` flips from NULL to Alice Smith. Focal's
   `load_rel.sh` would leave the order attached to both customers (its
   known driving-key gap).
2. **Raw vs soft rules without a rebuild.** The vault stores OMS's raw
   `'P'`; `fact_order` translates it on read. Change the rule and history
   reflects it instantly. Focal translates at ingest and needs its
   delivery archive + `make rebuild` for the same guarantee.
3. **Entity presence as a first-class fact.** `dim_customer` excludes
   deleted customers because the status satellite says so — Focal's
   `v_customer` still lists them as attribute-less ghost rows.

## What Focal demonstrates that the vault does not

1. **Schema evolution without DDL.** A new attribute in Focal is a
   metadata row. Here it is `ALTER TABLE` on a satellite plus edits to a
   stage view, a stage-2 view, the loader SQL and the mart view — the
   per-table repetition you can read in `scripts/load_sats.sh` is exactly
   the surface that Data Vault shops end up generating. Three entities are
   hand-writable; thirty are not. (This is the code-generator cost that
   motivated the Focal framework in the first place.)
2. **Delivery replay.** Focal archives every delivery and can rebuild the
   warehouse from genesis (`make rebuild`), reassigning identical keys.
   The vault preserves every attribute *state* and presence assertion, but
   not the deliveries themselves — a loader bug here means fixing forward,
   not replaying. (Natural keys soften this: there is no key-assignment
   state to lose.)
3. **Attribute-grain history.** Focal versions each atomic context
   independently; a satellite versions the whole row. C001's D1 email
   change writes one narrow row in Focal's `customer_desc` but a full
   `rv_customer_hsat` row (name and signup date duplicated) here. At wide
   satellites and high churn that multiplies; DV's answer is splitting
   satellites by rate of change — more tables, same trade.

## Row-count comparison after the identical demo

Same six deliveries, both models, derived tables only:

| concept | Focal | Data Vault |
|---|---|---|
| customer keys | `customer_idfr` 3 + `customer_focal` 3 | `rv_customer_h` 3 |
| customer attributes | `customer_desc` 16 rows (narrow: per context, incl. closing rows) | `rv_customer_hsat` 4 rows (wide, per change; deletes write none) |
| customer presence | inside `_desc` via `row_st` | `rv_customer_sts` 5 rows |
| order↔customer | `order_customer_x` 2 | `rv_order_customer_l` 2 + effsat 2 |
| business views | pivot + `MAX(CASE…)` per read | key-per-row joins, no pivot |

Neither column is "smaller" once presence and effectivity are accounted
for; they spend their rows on different questions.

## Layout

```
schema/01_stage.sql           stage L1 tables, load params, load audit
schema/02_stage2_views.sql    system columns + diff_str + recency dedup
schema/03_raw_vault.sql       hubs, satellites, status sats, links
schema/04_business_vault.sql  insert-only effectivity sat + LEAD views
schema/05_info_mart.sql       dim_customer / dim_product / fact_order + audit views
scripts/load_feed.sh          driver: stage → hubs → sats → links, load control
scripts/load_hubs|sats|links.sh   the three loaders (cf. Focal's keys/desc/rel)
source/d0..d5*.sql            the six deliveries, wide restatement of Focal's
tests/run_tests.sh            77 assertions incl. mutation-hardened idempotence
tests/fixtures/d6_repoint.sql the driving-key scenario Focal cannot express
```
