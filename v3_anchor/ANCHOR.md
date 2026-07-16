# Anchor Modeling — same deliveries, fourth model

The 6NF leg of the model-comparison set. The **same six narrow deliveries**
(byte-identical files shared with `../v3_focal-point`) flow into an
Anchor constellation: 3 anchors, 3 knots, 16 individually typed attribute
tables, 2 ties — **24 tables for the data the Focal demo holds in 4 generic
ones**. That number is the exhibit: Anchor and Focal share the same goals
(attribute-grain history, insert-only, non-destructive evolution) and take
exactly opposite physical routes.

```bash
make demo     # fresh archive + the full delivery sequence + perspectives
make rebuild  # throw the constellation away; replay the raw layer
make test     # 72 assertions, mutation-hardened
```

## Anchor vs Focal: the same idea, inverted

| | Focal Point | Anchor |
|---|---|---|
| an attribute is | a *row* (`type_key`) in one generic table | its *own table* with a typed column |
| Product_Price lives in | `val_num REAL` slot, meaning via metadata | `PR_PRC_Product_Price.Product_Price REAL` |
| add an attribute | INSERT into metadata; zero DDL | CREATE TABLE; zero ALTER |
| meaning lives in | metadata rows (`meta_atomic_context`) | the schema itself |
| constraints | none per attribute (generic slots) | per-attribute types, FKs, knot domains |
| customer after D0–D5 | 22 rows across 3 tables | 21 rows across 6 tables |
| loader | one generic engine | one generic engine — **the same loop**, retargeted |

The last line is the build's finding: `load_attributes.sh` is structurally
Focal's `load_desc.sh` — a metadata-driven loop — except each iteration
inserts into that attribute's own typed table. The narrow key-value landing
made that a retarget, not a rewrite, because it is already at attribute
grain (Anchor and Focal consume the same files; DV and Kimball share the
wide ones).

## No loading doctrine, so we brought one

Anchor's literature is a modeling and query-optimization body of work; the
official tooling generates DDL and insert triggers, not pipeline
discipline. The only stated load rule is **restatement control** — do not
insert a value equal to the attribute's latest — which is precisely the
sibling demos' NOCHANGE. Everything else here is the shared discipline,
ported: mode-aware deletes, tombstones, load control, capture-raw-then-
apply, ordered replay. Each lands on a natively Anchor construct:

| shared mechanism | Anchor landing spot |
|---|---|
| NEW/CHANGE/NOCHANGE | restatement control per attribute table |
| deletes (tombstone always; absence only under FULL) | the `EST` **existence knot**: presence is *data*. Anchor has no `row_st` to flip, so deletion must be modeled — the ghost-row gap the Focal demo documents cannot arise structurally |
| P→PENDING | the `OST` **knot**: raw code resolved at load, label read at query. Relabel = one `UPDATE`, all history follows; `make rebuild` resets to the seed (same lesson as Kimball's Type 1) |
| unknown codes | knots are **closed domains**: an unseen status fails the load loudly and the delivery stays retryable, staged rows preserved as forensics |
| D7 re-point | **historized tie**, latest-per-driving-role; end dates computed via `LEAD`, never stored — Anchor's native equivalent of the DV effectivity satellite |
| surrogate keys | per-anchor sequences over the `*_REF` registry (base 1000, `ORDER BY` key) — identical values to Focal's, reproduced by ordered replay |

Two Anchor idioms worth noticing in the schema: **even the business key is
an attribute** (`CU_REF_Customer_Reference` — identity and identification
are separate facts), and **static vs historized is declared per attribute**
(a signup date has no `ChangedAt`; an email does).

## What the constellation gives up

- **Table count grows linearly with the model.** 16 attribute tables for
  ten mapped attributes plus presence; a real domain multiplies this fast,
  which is exactly why the official tooling is a generator. The hand-written
  `04_views.sql` — twelve near-identical "latest" views — is the honest
  glimpse of that. (You left DV to escape generators; Anchor needs them
  *more*, not less.)
- **Every read is a join fan-out.** `v_customer` touches six tables;
  Anchor's answer in production is generated point-in-time views and
  engine-level table elimination, neither of which SQLite provides.
- **Evolution is DDL after all** — additive-only and non-destructive, but a
  new attribute is still a migration artifact, where Focal's is a metadata
  row a running system can absorb.

## Deviations from canonical Anchor, documented

Column names drop the mnemonic prefix (`CU_NAM_CU_ID` → `CU_ID`) for join
legibility; `OST` is a "described" knot carrying code + label so the shared
rule-change test works; mnemonic `OD` rather than `OR` (bare `OR` is a SQL
keyword); `Metadata_LDTS` stands in for Anchor's metadata construct; no
positor/reliability machinery (concurrent-reliance modeling is out of scope
for all four demos).

## Layout

```
schema/01_landing.sql   narrow landing (Focal-identical) + loader metadata maps
schema/02_archive.sql   raw layer: append-only, no unlock path, manifest
schema/03_anchor.sql    the 24-table constellation + knot and map seeds
schema/04_views.sql     latest perspectives, business views, timelines
scripts/load_feed.sh    capture-raw-then-apply, content-drift guard,
                        clear-on-success / forensics-on-failure
scripts/apply_delivery.sh  one shared path for ingest AND replay
scripts/load_anchors.sh    identities + *_REF registry (deterministic keys)
scripts/load_attributes.sh metadata-driven per-attribute loop + existence
scripts/load_ties.sh       historized / static ties
scripts/rebuild.sh         ordered replay of the archive
source/d0..d5*.sql         byte-identical copies of the Focal deliveries
tests/run_tests.sh         72 assertions; FULL-guard, restatement-control,
                           tie-guard and replay-order mutations all verified
tests/fixtures/            d6_tiebreak (dedup), d7_repoint (driving role)
```
