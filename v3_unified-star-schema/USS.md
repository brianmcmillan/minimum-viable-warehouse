# Unified Star Schema: a presentation model on top of a history core

Francesco Puppini's Unified Star Schema, presented with Bill Inmon, is not
a rival to the other models in this repo so much as a layer that sits
above them. It doesn't ask how to store history. It asks how to lay data
out so a self-service user can't get a wrong total. Its answer is one
bridge table in the middle of a star whose points are *all* the tables.

Same wide deliveries as the DV, Kimball, Inmon, HOOK, Activity Schema and
OBT demos, byte-identical.

```bash
make demo     # fresh archive + the full delivery sequence + views
make refresh  # re-derive the USS from the core
make rebuild  # regenerate core + USS by replaying the raw layer
make test     # 113 assertions, mutation-checked
```

## The ideas

- **Oriented model.** Every relationship is read many-to-one: line → order,
  line → product, order → customer. The bridge follows those arrows.
- **The Puppini bridge.** A `UNION ALL` of one *stage* per table. A stage
  row has its own key and every key it reaches downstream, so the order
  line row carries the customer key it reaches through the order.
- **Tables without foreign keys.** Each table keeps its attributes and one
  key, `_key_<table>`. All joins go through the bridge, `LEFT`, one key each.
- **Measures on their own stage.** A measure lives on the stage of the table
  it belongs to and is `NULL` elsewhere. Summing over the bridge therefore
  never repeats a value. That kills the fan trap.
- **A stage for every table.** Members with no related rows still have a
  bridge row. That kills the chasm trap.

## Where this implementation follows the USS, and where the shared discipline fills in

| concern | USS | this demo adds |
|---|---|---|
| presentation shape | bridge + key-only tables | — |
| keys | `_key_<table>`, from natural keys | composite `order_ref|sku` for order lines |
| history | out of scope; sits on a warehouse | an insert-only core, one table per entity |
| loading | out of scope | the shared delete rule, NOCHANGE suppression, the generic loader from the HOOK leg |
| refresh | build the bridge from the source tables | full re-derive after every delivery, in one transaction |
| business rules | wherever the warehouse puts them | decoded at refresh; raw code kept on `orders.status_code` |
| raw retention | — | the shared verbatim archive and exact rebuild |

Loops (two paths between the same tables) and multiple fact grains with
shared dimensions are where the USS does its subtler work. This corpus has
one path per relationship, so neither is exercised here.

## The same events, compared

| event | USS (this demo) | Kimball | Data Vault 2.0 | HOOK | OBT |
|---|---|---|---|---|---|
| attribute change | core row; USS re-derived | expire + new SCD2 version | new satellite row | new frame row | derived from the log |
| delete | core `DELETE` row; member leaves its stage | deleted-marker version | status-satellite row | `DELETE` frame row | derived from the log |
| relationship | key on the bridge, propagated transitively | FK in the fact | link + effectivity satellite | a second hook | a column |
| re-point (D6) | order **and its lines** move to C001 on the bridge | fact restated | new link + effectivity flip | new order row | derived |
| two grains in one query | correct by construction | correct only via separate facts or drill-across | the analyst's job | the analyst's job | the analyst's job |
| point-in-time | from the core | frozen surrogate (equi-join) | satellite as-of | as-of over frames | `LAG` over the log |
| business rule | at refresh | decode dimension | on read | on read | on read |

## What the demo shows

**The fan trap, measured.** `v_fan_trap` puts the naive join total (78.48)
next to the bridge total (48.99) and the true total (48.99). The suite
checks it after D0, after the tombstone, and after the re-point.

**Transitive keys do real work.** `order_line` has no customer column, but
its bridge row has `_key_customer`. When D6 moves O-101 to C001, the
refresh moves the order's row *and* its line's row, so "lines by customer"
is right without anyone remembering to re-join through orders.

**Deletes don't lose money.** After C002 is deleted, O-101's bridge row
still points at C002, so its 19.5 stays in every total. It shows up in
sales by customer with no name, which is the honest answer.

**Two tiers, two speeds.** The core is insert-only and never changes. The
USS is rebuilt freely. A decode change is a `make refresh`, not a reload,
and `make rebuild` reproduces both tiers exactly.

## What it costs

- History is somebody else's job. Without the core, the USS would be a
  current-state snapshot.
- The bridge gets wider with every table and longer with every row of
  every table. Simple to query, not free to store or refresh.
- Measures stay at their grain. That's correct, and it means allocations
  are still a modeling decision.
- The layer is materialised. Freshness is the refresh schedule.
- The design work moves to the bridge: deciding the stages, the
  directions, and how to break loops is where a real USS takes effort.

## Layout

```
schema/01_stage.sql     wide stage L1 (shared shape) + L2 dedup/diff views
schema/02_archive.sql   raw layer: append-only wide history + manifest
schema/03_core.sql      core_table registry, insert-only core, latest views, ref data
schema/04_uss.sql       USS tables, _bridge, business / trap / history views
scripts/load_core.sh    the generic, registry-driven core loader
scripts/refresh_uss.sh  full re-derive of the USS tables and the bridge
tests/run_tests.sh      113 assertions
```
