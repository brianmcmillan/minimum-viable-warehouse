# HOOK: model as little as possible, hook everything

Andrew Foad's HOOK approach asks one question of every other model in this
repo: *how much of that structure did you actually need at load time?* Its
answer is: almost none. Keep the source tables. Qualify the business keys.
Build everything else as views.

Same wide deliveries as the DV, Kimball, Inmon, USS, Activity Schema and
OBT demos, byte-identical.

```bash
make demo     # fresh archive + the full delivery sequence + views
make rebuild  # regenerate the frames by replaying the raw layer
make test     # 99 assertions, mutation-checked
```

## The four ideas

- **Core Business Concepts** are the nouns the business uses: CUSTOMER,
  PRODUCT, ORDER. They live in a glossary (`hook_concept`), not as tables.
- **Key sets** say which system minted a key (`CRM.CUST`, `PIM.SKU`,
  `OMS.ORD`). Two keys are the same thing only if they share a key set *and*
  a value. This is the only integration decision HOOK forces up front.
- **Hooks** are `'<key set>|<key>'` values in `hk_<concept>` columns. A row
  carries one hook per concept it mentions, which is how relationships exist.
- **Frames** are the source tables plus hooks plus load metadata,
  insert-only. (Some earlier HOOK writing calls them *bags*.)

## Where this implementation follows HOOK, and where the shared discipline fills in

HOOK prescribes the shape of the warehouse. It says much less about loading
discipline, so the shared rules fill the gap, as they did for Anchor:

| concern | HOOK | this demo adds |
|---|---|---|
| warehouse shape | frames + hooks, no hubs/links | — |
| registry | concepts and key sets | `hook_frame` / `hook_column`, so one loader and one integrity check cover every frame |
| change capture | frames hold changes | `diff_str` NOCHANGE suppression; `change_type` per row |
| deletes | not prescriptive | the shared rule: tombstone always, absence only under FULL, written as `DELETE` rows with a `delete_basis` |
| raw retention | frames are close to a PSA | a separate verbatim archive, because frames drop restatements and dedup losers |
| business rules | downstream | views over frames; `ref_oms_order_status` decoded on read |

Key-set *mapping* (one system's customer number to another's) is a real HOOK
concern that this corpus never triggers: OMS already uses CRM's numbers. The
suite still shows what happens without a mapping. A hook in the wrong key set
is flagged and does not integrate.

## The same events, compared

| event | HOOK | Data Vault 2.0 | Kimball | Inmon 3NF | OBT |
|---|---|---|---|---|---|
| attribute change | new frame row (`UPDATE`) | new satellite row | expire + new SCD2 version | close + insert | nothing stored; derived from the log |
| delete | `DELETE` frame row + `delete_basis` | `'D'` status-satellite row | deleted-marker version | close + `is_deleted` row | derived from the log |
| unchanged re-delivery | writes nothing | writes nothing | writes nothing | writes nothing | **stored again** |
| relationship | a second hook on the row | link + effectivity satellite | FK in the fact | natural-key FK column | a column |
| re-point (D6) | new order row with a new `hk_customer` | new link + effectivity flip | fact restated | new order version | derived |
| "all customers" | `GROUP BY` over hooks (view) | the hub (table) | the dimension (table) | the entity table | `DISTINCT` over the log |
| business rule | on read | on read | decode dimension | at ingest | on read |
| loader code | **one generic engine** | per entity | per entity | per entity | one refresh query |
| row mutation | never | never | dims expire | rows close | never |

## What the demo shows

**HOOK is Data Vault without the hub.** Strip the hub out of DV, fold the
business key back onto the satellite row, and fold the link's other key onto
the same row: that is a frame. The suite proves nothing is lost for this
scenario. Current state, deletes, as-of answers, and the re-point all work,
and the hub can still be produced as `v_concept_member` when someone asks.

**One loader for everything.** Because frames are source-aligned, every frame
loads the same way, and `load_frames.sh` reads the registry instead of naming
entities. That is the property Focal Point gets from going narrow and generic.
HOOK gets it while keeping wide, typed, source-shaped tables.

**The re-point is boring, which is the point.** DV needs a driving-key
effectivity satellite. Focal currently can't express it. In HOOK the order row
changed, so a new order row lands with a different `hk_customer`, and the
latest row has exactly one customer by construction.

**No ghost rows.** A delete is the latest frame row, so the latest-row views
drop the subject without any `is_current` flag to maintain.

## What it costs

- The integration point is computed, not stored. Every "list the customers"
  is a scan over every frame that hooks CUSTOMER.
- Matching is exact-value matching. Key-set discipline is the whole
  integration story, and mapping work is deferred, not avoided.
- All semantics live in views. Rule changes are instant and history-wide,
  and query cost grows accordingly.
- Frames are coupled to source shapes. A restructured source means a
  restructured frame.
- Delta frames can't re-derive FULL-snapshot absences after the fact. The
  delete must be written while the snapshot is in the stage. OBT keeps
  everything and can derive it later; HOOK chose compression.

## Layout

```
schema/01_stage.sql     wide stage L1 (shared shape) + L2 views that build the hooks
schema/02_archive.sql   raw layer: append-only wide history + manifest
schema/03_hook.sql      registry (concepts, key sets, frames, hook columns), frames, ref data
schema/04_views.sql     latest rows, business views, as-of, hub on demand, hook integrity
scripts/load_frames.sh  the generic, registry-driven delta loader
tests/run_tests.sh      99 assertions
```
