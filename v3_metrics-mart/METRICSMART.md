# Metrics mart: a 3NF model that is already half metadata

The ER diagrams in [`../docs/metrics-mart-notes.pdf`](../docs/metrics-mart-notes.pdf)
describe a warehouse for measurements: resources, the metrics taken on them,
and rollups by week and by group. It is 3NF with its codes snowflaked out
(`RES_TYPE`, `VALUE_TYPE`, `CAL_EVT_TYPE`).

It is also closer to Focal Point than it looks. `METRIC` is a table of
attribute definitions. `METRIC_SAMPLE` is a narrow fact keyed by resource,
attribute and time. For numbers, this model made the Focal move years ago
and kept it typed. For everything that isn't a number, it is plain 3NF.

Same wide deliveries as every other model, byte-identical, unpivoted into
the same narrow landing as the Focal Point and Anchor demos.

```bash
make demo     # fresh archive + the full delivery sequence + views
make rebuild  # regenerate the mart by replaying the raw layer
make test     # 222 assertions, mutation-checked
```

## Review of the diagrams

### What the design gets right

- **Two-step metric staging.** `METRIC_STG` carries names (resource type and
  alias, metric code, provider name). `METRIC_STG2` carries the same rows
  with every name resolved to a surrogate. The resolution step is visible,
  testable and restartable.
- **Identity resolution is in the model.** `RES_ALIAS` lets each provider
  call a resource what it likes and maps every name to one `res_id`. Focal
  and Anchor, which load the same files, have no such table.
- **A metric is data.** Adding a measurement is a row in `METRIC`, not a
  column on a fact. `VALUE_TYPE` says how to read it.
- **Staging has what a loader needs for ordering and deletes.** `batch_no`
  names the delivery, `sequence_no` orders rows within it, and `load_oper`
  carries an explicit delete.
- **Samples and summaries are separate tables.** A provider can deliver raw
  observations, pre-summarised intervals, or both, and `summary_level` keeps
  them apart.

### What I'd question

| # | finding | what this demo does about it |
|---|---|---|
| 1 | **Nothing says whether a batch is full or incremental.** `load_oper` handles an explicit delete, but a resource missing from a batch is ambiguous. | The shared rule: absence deletes only under a FULL delivery. The router decides and writes `load_oper = 'D'`. |
| 2 | **`RES` keeps no history.** No validity columns, so a changed name or parent overwrites the old one. | Built as drawn. The archive is the only history of descriptors, and the suite asserts that. |
| 3 | **`RES_ALIAS` is not qualified by provider.** The key is `(res_type, res_alias)`. Two providers using one name for different resources of the same type collide. | Built as drawn; noted as the wall a second source would hit first. |
| 4 | **`RES_TYPE_REL` is not enforced.** It lists allowed parent/child type pairs, but `RES.parent_res` is a plain self-reference. | A view of violations, checked before every resource load commits. |
| 5 | **`RES_GRP` stores one hierarchy three ways:** `parent_res_grp`, `group_level` and `group_path`. Nothing keeps them in step. | The loader derives parent and level from the path; a second view checks all three agree. |
| 6 | **One parent per resource.** Anything with two parents has to put one of them in a group. | Order lines become group memberships. |
| 7 | **No business keys are declared.** Only surrogate primary keys are shown on `RES`, `METRIC`, `PROVIDER` and `RES_GRP`. | Unique keys added on `(res_type, res_code)`, `metric_code`, `provider_name` and `group_path`. |
| 8 | **A corrected sample has nowhere to go.** The key of `METRIC_SAMPLE` is resource, metric, time and provider. A second value for the same key must overwrite or be refused. | Overwrite. The archive keeps both values. |
| 9 | **`RES_RESGRP` has no dates or status.** A membership that ends is a physical delete, and group aggregates for past weeks use today's members. | Built as drawn; stated in the README as a limit. |
| 10 | **Small inconsistencies.** `METRIC_WEEKLY` uses `FLOAT` and `GRP_METRIC_WEEKLY` uses `DOUBLE` for the same measures. `lcl_tz_code` is a foreign key on one and not the other. `METRIC_SAMPLE` has `srcd_d2k SMALLINT` where every other table has `srcd_ts`. `COUNTRY` has no key. | Types kept as drawn. `srcd_d2k` is read as days since 2000-01-01. |
| 11 | **Foreign keys to tables that aren't shown:** `site_id`, `support_ctr_id`, `client_id`, `prvdr_inst_id`. | Plain nullable columns. |
| 12 | **`CALNDR_EVENT` refers to a resource by `res_type` and `res_code`,** not `res_id`. An event may need to apply to one resource, a group, a sub-group or a whole type; this key reaches only a type or one resource, and a recoded resource loses its events. `res_code` is `VARCHAR(250)`, the width of `group_path`, and `inheritance_flag` is already there, so the design seems to have been reaching for group targets. | Not built. Calendar events were removed to keep the ten demos like for like; the tag `metrics-mart-with-calendar` has the version that targets a `RES_GRP` by `res_grp_id`. |
| 13 | **Local time is stored next to UTC** (`start_lcl_ts`, `res_tz_code`), and weeks are keyed on the local date. A resource that changes time zone changes its own history. | Not exercised: everything is UTC here. |

Findings 1, 2 and 3 are the ones that change what the mart can answer. The
rest are housekeeping.

## Does the Focal / Anchor design make sense here?

For the plumbing, yes. For the core, no.

**The narrow row is already the mart's staging shape.** One row of the
narrow landing (what `stage_narrow.sh` makes of a wide delivery, as for
Focal and Anchor) is `(source_system, source_entity, business_key,
attribute_name, value)`. One `METRIC_STG` row is `(provider_name, res_type,
res_alias, metric_code, value)`. They are the same five things. The narrow
landing and the metadata-driven routing carry over unchanged; the archive
is the shared wide one.

**The core should stay 3NF.** Moving `RES` into Focal's generic tables or
Anchor's attribute tables would give it history and DDL-free attributes. It
would also stop being the model in the diagrams. `METRIC` and
`METRIC_SAMPLE` already do the generic job for the numbers, which is where
the volume and the change are.

**One thing did not carry over.** The Focal and Anchor landing keeps the
newest row per key and attribute. That is right for a descriptor and wrong
for a measurement, because two prices at two times are two observations. The
first version of this loader lost a sample that way and the suite caught it.
Measurements now go from the stage to `METRIC_STG` with the time in the
dedup key.

## Where this implementation follows the diagrams, and where the shared discipline fills in

| concern | the diagrams | this demo adds |
|---|---|---|
| storage | 3NF core, snowflaked code tables | built as drawn; three subtype tables and two code tables for attributes `RES` has no column for |
| source shape | `*_STG` tables | the shared wide files, unpivoted to the narrow landing, routed into those tables by two metadata maps |
| identity | `RES_ALIAS` | one alias per resource (its own code); parents and metrics both resolve through it |
| change capture | not addressed | descriptors: update in place, changed rows only. Numbers: a new sample per observation |
| deletes | `load_oper`, `res_status` | the shared rule: tombstone always, absence only under FULL |
| full vs incremental | **not addressed** | `load_mode` on the delivery, read by the router |
| unknown parents | `RES_TYPE.autocrt_res_flag` | a stub resource when the flag is 1; a failed load when it is 0 |
| surrogates | integer ids | continued from the table maximum in business-key order, so replay reproduces them |
| aggregates | `METRIC_SUMMARY`, `METRIC_WEEKLY`, `GRP_METRIC_WEEKLY` | derived after every delivery; only rows whose numbers changed are touched |
| raw retention | not covered | a separate verbatim archive, the only history of descriptors |
| business rules | code tables | `ORDER_STATUS` closed (unknown code fails the load), `CURRENCY` open (the load adds codes), both decoded on read |
| calendar | `CALNDR`, `CAL_EVT_TYPE`, `CALNDR_EVENT` | `CALNDR` only, seeded for 2026-2027 and used for week boundaries; the event tables are not built (tag `metrics-mart-with-calendar`) |
| time zones | `TIME_ZONE`, `TZ_CODE` | not built; everything is UTC |

## The same events, compared

| event | Metrics mart | Inmon 3NF | Focal Point | Anchor |
|---|---|---|---|---|
| descriptor change | `UPDATE` in place | close the row, insert a version | new version row per atomic context | new row in that attribute's table |
| numeric change | new `METRIC_SAMPLE` row | close the row, insert a version | new `val_num` version row | new row in that attribute's table |
| delete | `res_status = 0` | closing version | closing row, `row_st='N'` | `DELETED` in the existence knot |
| unchanged re-delivery | descriptors: nothing. Numbers: **a new sample** | writes nothing | writes nothing | writes nothing |
| relationship | `parent_res`, or a group membership | natural-key FK | relationship loader | historized tie |
| re-point (D7) | parent overwritten | new order version | known gap | new tie row |
| "as at purchase" | **not answerable** | range join on validity | bi-temporal query | attribute as-of |
| new numeric attribute | a `METRIC` row | `ALTER TABLE` | a metadata row | a new table |
| new descriptive attribute | `ALTER TABLE` | `ALTER TABLE` | a metadata row | a new table |
| identity across sources | `RES_ALIAS`, unqualified | conform at ingest | single-namespace registry | one namespace |
| business rule (P→PENDING) | raw `'P'` + code table, on read | conformed at ingest | at ingest (`meta_value_map`) | knot, on read |
| row mutation | resources update; samples overwrite on correction | versions close | never | never |

## What the demo shows

**Numbers get history for free and nothing else does.** SKU-1's price is two
samples and both are still there. C001's old email is gone. The model draws
a hard line between what was measured and what was described, and it only
remembers the first.

**An unchanged value is still an observation.** Every sibling suppresses a
restated value. Here SKU-2's unchanged 19.5 is a second sample, because
"PIM looked again and it was still 19.5" is a fact a metrics mart exists to
keep. Only an exact repeat of an observation is suppressed, by the primary
key.

**A new metric is a row.** The suite inserts a `weight_kg` metric and one
map row, delivers a value, and checks that the sample and its weekly rollup
exist and that the schema did not change.

**Code tables are constraints.** An order with status `'X'` fails the load
on its foreign key. The step rolls back whole, the delivery stays `STARTED`,
and its staged rows are kept.

**The group aggregate has a meaning.** An order's members are its products,
so the group week for `price` is the basket at list price. It equals the
order amount in the week the order was placed and drifts from it when a
member is repriced.

## Calendar events, removed

An earlier version of this demo built the diagrams' calendar events: planned
events such as promotions and maintenance windows, attached to groups of
resources and joined to the samples taken while they were in effect. No
sibling model stores planned events, so the feature made this mart harder to
compare with the other nine, and it was removed. The tag
`metrics-mart-with-calendar` keeps it, with its tests. `CALNDR`, the day
table, stays and sets the week boundaries for the weekly rollups.

## What it costs

- **No point-in-time answers about descriptors.** Kimball answers "who placed
  this order, as they were then?" with a frozen key and the Activity Schema
  with a join on time. This model can't answer it. The archive could, with a
  rebuild as of a date.
- **Rows mutate.** A resource updates in place and a corrected sample
  overwrites. Without the archive, a wrong load is unrecoverable.
- **Descriptors are second-class.** Anything that isn't a number needs a
  column, and the diagrams give `RES` three text columns. Five of the
  corpus's ten non-key attributes needed tables the diagrams don't have.
- **Current value is a query.** A product's price is its newest sample, read
  through a window function. The Activity Schema and HOOK pay the same bill.
- **Identity is one unqualified namespace per type.** `RES_ALIAS` is real
  identity machinery, more than Focal or Anchor have. It still can't hold two
  providers that use the same name for different things.
- **Group history is rewritten.** Past group weeks are recomputed with
  current members.

## Mutation checks

Each change below was made to a copy of the scripts and the suite was run
against it. All of them turn the suite red.

- **Delete rule:** dropping the FULL guard on resources; ignoring
  tombstones; dropping the FULL guard on memberships; removing the
  membership absence delete; removing the membership tombstone.
- **Recency:** reversing the dedup order; reversing the same-extract
  tiebreak; taking the time out of the measurement dedup key.
- **Change detection:** removing the changed-rows-only guard on `RES`, on
  the subtype tables, and on `METRIC_WEEKLY`; ignoring a corrected sample.
- **Lifecycle:** removing the restore path; removing auto-create; letting a
  partial delivery null the name.
- **Scope:** removing the current-feeds filter, so a stale FULL snapshot is
  applied again.
- **Constraints:** switching foreign keys off; disabling the `RES_TYPE_REL`
  guard; running a load step without `sql_tx`, so a failed step can
  commit what it had already written.
- **Replay:** reversing the delivery order; reversing the row order within a
  delivery; replaying deliveries that never completed; numbering new
  resources out of business-key order.
- **Aggregates:** starting the week on Sunday.
The current-feeds mutation survived the first version of the suite. The
stale-snapshot assertions were added to catch it.

## A native narrow archive is a supported option

If your extracts really are narrow (an EAV export, or a change stream that sends one attribute at a
time), you can stage them straight into `source_landing_stage`, archive that shape (a
`source_landing_history`-style table keyed on file and row), and skip `stage_narrow.sh`. The loaders
don't change. Two costs come with it:

- **It makes switching harder, in both directions.** The models that take wide extracts can't
  replay a narrow archive, and the mart can't replay theirs, without a conversion step. The
  delivery files also stop being shared, so a cross-model comparison is no longer like for like.
- **It needs its own content-checked load-control guard.** The shared guard compares the wide
  stage with the `hist_*` tables only. A narrow archive must compare `source_landing_stage`
  with its own history table, every row and in order, to keep the same rule: a reused
  `file_id` whose rows differ is rejected, whether the delivery completed or crashed.

For this mart there is a third consideration, in its favour: a narrow archive keeps "a new metric is
a row" true all the way down, because a metric a source starts sending is just a new
`attribute_name`. With the wide raw layer it needs a new column (see README, "What the metrics mart gives up").

## Layout

```
schema/01_landing.sql          wide stage, narrow landing (shared shape) + routing metadata + load guard
schema/02_archive.sql          raw layer: append-only wide history (hist_*) + manifest
schema/03_mart.sql             staging and core tables from the diagrams, CALNDR, plus the added subtypes
schema/04_seed.sql             reference rows and the routing maps
schema/05_views.sql            business views, mart views, integrity views
scripts/stage_narrow.sh        wide stage -> narrow landing rows (ingest AND replay)
scripts/route_stage.sh         narrow landing -> the mart's staging tables; the shared delete rule
scripts/load_res.sh            resources, aliases, parents, subtype columns
scripts/load_groups.sh         groups, type groups and memberships
scripts/load_metrics.sh        METRIC_STG -> METRIC_STG2 -> METRIC_SAMPLE
scripts/refresh_aggregates.sh  summaries, weeks, group weeks
tests/run_tests.sh             222 assertions
```
