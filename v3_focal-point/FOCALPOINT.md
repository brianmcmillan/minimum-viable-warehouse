# Incremental-aware variant

The canonical variant assumed every delivery is a full snapshot, so
"absent ⇒ deleted" was always safe. Real feeds aren't like that. This
variant makes **ingestion strategy explicit** and gives the loader the
machinery a 14-day / 45-day / yearly cadence actually needs.

```bash
make demo            # baseline + 5 deliveries + views
make rebuild         # throw the warehouse away; replay the raw layer to rebuild it
make archive-status  # what the raw layer holds, and where it is growing
make test            # both suites: delete semantics, and the raw layer
```

## The core rule

> **Absence means DELETE only for a FULL delivery.**
> An INCREMENTAL (windowed) delivery never infers a delete from absence —
> deletes must arrive as an explicit **tombstone** (`op='DELETE'`) or be
> found later by a **FULL reconciliation**.

Strategy is declared per feed in `meta_source_feed`, and each delivery can
override it with a `load_mode` (a normally-incremental source can send a
periodic full). The loader resolves the effective mode per feed and only
enables the absence-delete branch when it is `FULL`.

## Answering the operational questions

**Do the loaders avoid loading duplicates?** Three layers now:

1. **File level** — `load_feed.sh` records every delivery in
   `loaded_files` by `file_id` and skips a re-sent file. Because the
   extractor overwrites the same filename, identity is the delivery id
   (batch/version), not the filename. A `file_id` names a delivery's
   *content*: re-sending it with different rows is rejected outright rather
   than silently ignored, since the archive would otherwise stop describing
   what was actually applied.
2. **Row level** — a delivery is recency-de-duped into `source_landing`:
   the newest row per `(source_system, source_entity, business_key,
   attribute_name)` by `extract_ts` wins (this replaces the canonical
   variant's naive `MAX(value)`, which could keep a stale value).
3. **Version level** — the descriptor delta still classifies unchanged
   facts as `NOCHANGE`, so even a genuine re-run writes nothing.

**Would a 60-day-stale record look deleted in a 14-day feed?** No — that
was the trap, and it's now closed. In the test, the day-60 window carries
only the changed customer (C001); the 60-day-stale C002 is absent and
stays fully active. Under a FULL product snapshot in the same run, a
discontinued SKU *is* deleted. Same engine, opposite outcome, driven only
by the delivery's mode.

## How deletes actually happen in an incremental world

- **Tombstone** — the extractor emits an `op='DELETE'` row for a
  `business_key` (see `d3_cust_tombstone.sql`). The loader closes that
  entity's descriptors (`row_st='N'`) immediately.
- **Periodic full reconciliation** — your yearly batch arrives as
  `load_mode=FULL` (see `d5_cust_yearly_full.sql`); anything absent from
  that complete snapshot is deleted. This is the safety net that catches
  deletes the incremental stream never announced.

## The delivery sequence the tests run

| # | file | feed / mode | what it proves |
|---|------|-------------|----------------|
| D0 | `d0_baseline.sql` | all / FULL | initial full load |
| D1 | `d1_cust_win_day60.sql` | CRM.CUSTOMER / INCREMENTAL | 14-day window updates C001, **does not** delete stale C002 |
| D2 | `d2_prod_full_v2.sql` | PIM.PRODUCT / FULL | absence **does** delete discontinued SKU-3 |
| D3 | `d3_cust_tombstone.sql` | CRM.CUSTOMER / INCREMENTAL | explicit tombstone deletes C002 |
| D4 | `d4_cust_recency.sql` | CRM.CUSTOMER / INCREMENTAL | duplicate attribute → newest by `extract_ts` wins |
| — | re-send D1 | — | duplicate `file_id` skipped by load control |
| D5 | `d5_cust_yearly_full.sql` | CRM.CUSTOMER / FULL | yearly reconciliation deletes C003 (gone at source) |

## The raw layer: the warehouse is disposable

There are **two databases**. `build/focal.db` is derived and throwaway.
`archive/focal_archive.db` is the raw layer: every delivery ever accepted,
captured verbatim *before* it is applied, append-only, plus the `loaded_files`
manifest that says what arrived and in what order.

`make rebuild` drops the warehouse and replays the archive through the *same*
loaders that ingested it (`apply_delivery.sh` — ingest and replay share one code
path, or a green rebuild would prove nothing about ingest).

This is the Data Vault "single version of the facts" property, and it buys two
things the framework previously could not do:

- **Fix a loader bug.** Correct the code, `make rebuild`. There is no restore
  from backup, because the raw input was never destroyed.
- **Change a business rule retroactively.** `load_desc.sh` translates `'P'` into
  `'PENDING'` at ingest via `meta_value_map` — but the raw `'P'` now survives in
  `source_landing_history`. Edit the rule in `schema/03_seed_metadata.sql`, run
  `make rebuild`, and the whole history is re-derived under the new rule.
  (Edit the *seed*, not the table: `rebuild` recreates `focal.db` from schema.)

### Rebuild reproduces surrogate keys, and that is load-bearing

Keys are allocated `MAX(key) + ROW_NUMBER() OVER (ORDER BY idfr)`, which depends
on the order identifiers are first seen. Replaying the archive reproduces them
*exactly* — but only because three orderings are guaranteed:

1. deliveries replay in `load_seq` order (ingest order). Replay `D4` before `D0`
   and `C003` gets key `1001` instead of `1003`.
2. a delivery's rows are restored to `source_landing_stage` in `seq_nbr` order,
   because the recency-dedup tiebreak is `ORDER BY extract_ts DESC, rowid DESC`.
   When two rows carry the same `extract_ts`, physical order decides.
3. `load_keys.sh` iterates feeds in a fixed order.

Each has a regression test in `tests/test_archive.sh`.

### Why there is no retention policy

Because pruning would break all of the above. Replaying a *subset* of deliveries
reassigns every surrogate key, and pruned attributes are gone permanently — a
key registry or hashed keys would preserve the *key*, never the data. **The
archive is only a backup while it is complete**, so nothing in this project
deletes an archived row: the append-only triggers in `schema/05_archive.sql`
have no unlock path.

The cost is unbounded growth, and FULL feeds dominate it — `PIM.PRODUCT`
re-archives the entire catalogue on every delivery, changed or not. That is
unavoidable: absence-means-delete can only be replayed if the full snapshot was
captured. `make archive-status` reports rows per feed so the growth is visible.

If you ever do need retention, restoring key stability first requires either a
durable identifier→key registry in the archive, or deterministic (hashed) keys.

## What changed vs. the canonical variant

- `source_landing` gains `op` (UPSERT/DELETE) and `load_mode`.
- New `source_landing_stage` (delivery lands here, then recency-deduped) and
  `meta_source_feed` (declared strategy).
- New **archive database**: `source_landing_history` (append-only raw layer) and
  `loaded_files` (load control). It lives outside `build/`, so `make clean` and
  `init_db.sh` cannot destroy it; `make clean-archive` is the only thing that does.
- `load_feed.sh` driver: stage, verify the delivery matches what was archived
  under that `file_id`, archive it, apply it, and only then mark it `COMPLETE`.
  A delivery that crashes mid-load stays retryable rather than being skipped as done.
- `apply_delivery.sh`: the one path from staged rows to the warehouse, shared by
  `load_feed.sh` (ingest) and `rebuild.sh` (replay).
- `load_desc.sh` / `load_rel.sh` branch on mode: absence-delete only for FULL,
  tombstone-delete always, NEW/CHANGE/NOCHANGE unchanged.
- Data layer (`02_data.sql`) and semantic views (`04_views.sql`) untouched.

Maps directly to Daana's ingestion strategies (`FULL`, `INCREMENTAL`,
`FULL_LOG`, `TRANSACTIONAL`) and the Top of Minds principle that the load
strategy is a property of the *source*, decided per feed — not baked into
one global loader.

## Known gap: driving-key relationship effectivity

`load_rel.sh` knows three deltas — NEW, tombstone-DEL, FULL-absence-DEL —
but not *re-pointing*: when an incremental delivery moves an order from
one customer to another, the new pair is inserted and the old one stays
active. One order, two live customers — and `v_order.placed_by` becomes
undefined (its subquery picks one of the two with `LIMIT 1`, no
`ORDER BY`).

Every sibling demo handles this scenario natively (DV effectivity
satellite, Kimball fact update, Inmon order versioning, Anchor historized
tie, OBT latest-wins), so the gap is kept **executable** here rather than
just documented: `tests/fixtures/d7_repoint.sql` loads the re-point, the
suite asserts today's defective state (both pairings active) as a regular
test, and asserts the desired state as expected failures — amber `GAP`
lines with the suggested fix printed beneath them. If the fix lands, those
lines flip to a red `XPASS` telling the fixer to promote them. The fix
itself is small: a declared driving role per relationship in
`meta_relationship`, plus a `del_repoint` CTE in `load_rel.sh` mirroring
`del_tomb`.
