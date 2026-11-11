# Inmon-style 3NF EDW — the control group

The design every other leg of this repo reacts to: a subject-oriented,
integrated, time-variant, non-volatile normalized core — Inmon's four
adjectives, rendered the classic way. Same wide deliveries as the DV,
Kimball, HOOK, USS, Activity Schema and OBT demos, byte-identical.

```bash
make demo     # fresh archive + the full delivery sequence + views
make rebuild  # regenerate the EDW by replaying the raw layer
make test     # 64 assertions, mutation-hardened
```

## What "classic" means here

- **Natural keys.** `customer_ref` *is* the key; `orders.customer_ref` is a
  plain FK column. No surrogates, hubs, anchors, or ties — the relationship
  is just third normal form.
- **Time-variant rows.** Every entity table carries `valid_from`/`valid_to`;
  a change *closes* the current row (an `UPDATE`) and inserts a new one.
  Current and history live in one table. Deletes follow the shared rule
  (tombstone always, absence only under FULL) and land as a closed row plus
  an `is_deleted` marker carrying last-known attributes.
- **Integrated = conformed at ingest.** The EDW stores `PENDING`, not `'P'`
  — cleansing happens on the way in, via the normalized
  `order_status_ref` table. Unknown codes are flagged
  (`UNKNOWN(<code>)`), not rejected: classic EDW cleansing tolerance,
  deliberately different from Anchor's closed knots.
- **In the CIF picture, the Kimball leg sits downstream of this one**: the
  `v3_data-marts` star is exactly the kind of departmental mart the EDW
  would feed.

## What the control group demonstrates (both directions)

**Where it holds up better than its reputation.** A *time-variant* 3NF core
handles the whole shared scenario correctly: the stale-window trap, the
tombstone, the FULL reconciliation, zero-churn re-deliveries, even the D6
re-point — which simply versions the order row, keeping the old pairing as
queryable history. Inmon's EDW was never the strawman "current-state-only"
database; the suite proves it.

**Where the pain lives, made visible by tests:**

1. **Queries follow the current world.** `v_order` joins `customer` by
   natural key, so `placed_by` always shows the *current* name — and turns
   NULL the moment C002 is deleted. Point-in-time needs the **range join**
   in `v_order_as_recorded` (`o.valid_from >= c.valid_from AND <
   c.valid_to`) — the BETWEEN gymnastics that Kimball's frozen surrogate,
   DV's satellites, and Anchor's latest-views all exist to avoid.
2. **Conformance at ingest is a one-way door — without an archive.** The
   suite changes `order_status_ref` live and proves stored rows keep the
   old label. Classic CIF stops there: re-conforming history meant
   re-extracting from sources. The shared raw layer is this demo's one
   deliberate modernisation, and the escape hatch is asserted: edit the
   seed, `make rebuild`, and history re-derives under the new rule.
3. **Schema evolution is `ALTER TABLE` on populated history tables** —
   stated, not tested; there is no non-destructive path here, which is the
   single strongest argument each successor model makes against this one.

## Layout

```
schema/01_stage.sql    wide stage L1 (shared shape) + L2 dedup/diff views
schema/02_archive.sql  raw layer: append-only wide history + manifest
schema/03_edw.sql      time-variant 3NF entities, order_status_ref, views
scripts/load_feed.sh   capture-raw-then-apply, clear-on-success
scripts/apply_delivery.sh  one shared path for ingest AND replay
scripts/load_edw.sh    the single merge loader: close -> insert -> markers
scripts/rebuild.sh     ordered replay of the archive
source/d0..d5*.sql     byte-identical copies of the v3_datavault deliveries
tests/run_tests.sh     64 assertions; FULL-guard, churn-guard and
                       replay-order mutations all verified to fail it
tests/fixtures/d6_repoint.sql  the restatement fixture (an order VERSION here)
```
