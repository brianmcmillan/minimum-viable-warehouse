# One dataset, ten warehouses

[![ci](https://github.com/brianmcmillan/minimum-viable-warehouse/actions/workflows/ci.yml/badge.svg)](https://github.com/brianmcmillan/minimum-viable-warehouse/actions/workflows/ci.yml)

Data-modeling debates never end because nobody runs the experiment. So I
ran it. This repo holds ten complete, working warehouses: an Inmon-style
3NF EDW, a Kimball star, Data Vault 2.0, Focal Point, an Anchor Modeling
constellation, HOOK, a Unified Star Schema (USS), an Activity Schema, a
metrics mart and One Big Table (OBT, no model at all). All ten take the
same six load files and enforce the same load semantics. All ten answer
the same nine questions, from who is live now to who placed an order
before it was re-pointed, but they don't all answer them the same way.
[`ANSWERS.md`](ANSWERS.md) has the matrix. In 84 of the 90 cells the
model answers from its own tables. In four, the Unified Star Schema
answers from the insert-only core under its bridge. In two, Inmon and
Focal can't relabel history without a rebuild, because both apply the
rule when a row is stored. That's where the model makes a difference.

So far, though, the ten only prove they agree on load mechanics. Every
entity has exactly one source, so none of them has had to decide who a
customer is. The last section says what would test that.

Together they cover the whole argument: no model, normalized,
dimensional, vault, attribute-grain (generic and typed), hooks over
source-shaped frames, activities in place of entities, resources and
their measurements, and a bridge built so self-service can't
double-count.

Each one is native SQLite, bash and Make. No Python, no packages, no
server. The sqlite3 that ships with macOS is enough.

The ER diagrams in [`er-diagrams/`](er-diagrams/) are an optional extra
outside the ten warehouses. They are built with Python, the Mermaid CLI
and pypdf; no warehouse, suite or `make` target needs them.

```bash
cd v3_inmon-3nf           && make demo && make test   # Inmon 3NF (control group)
cd v3_data-marts          && make demo && make test   # Kimball star
cd v3_datavault           && make demo && make test   # Data Vault 2.0
cd v3_focal-point         && make demo && make test   # Focal Point
cd v3_anchor              && make demo && make test   # Anchor Modeling
cd v3_hook                && make demo && make test   # HOOK
cd v3_unified-star-schema && make demo && make test   # Unified Star Schema
cd v3_activity-schema     && make demo && make test   # Activity Schema
cd v3_metrics-mart        && make demo && make test   # Metrics mart (3NF snowflake)
cd v3_one-big-table       && make demo && make test   # One Big Table (null hypothesis)
```

| directory | model | derived layer | durable raw layer |
|---|---|---|---|
| [`v3_inmon-3nf/`](v3_inmon-3nf/README.md) | [Inmon time-variant 3NF EDW](v3_inmon-3nf/INMON.md) (natural keys) | `build/edw.db` | `archive/edw_archive.db` |
| [`v3_data-marts/`](v3_data-marts/README.md) | [Kimball star](v3_data-marts/DATAMART.md) (SCD2 + facts) | `build/datamart.db` | `archive/datamart_archive.db` |
| [`v3_datavault/`](v3_datavault/README.md) | [Data Vault 2.0](v3_datavault/DATAVAULT.md) (natural keys) | `build/datavault.db` | `archive/datavault_archive.db` |
| [`v3_focal-point/`](v3_focal-point/README.md) | [Focal Point](v3_focal-point/FOCALPOINT.md) (metadata-driven, narrow/EAV) | `build/focal.db` | `archive/focal_archive.db` |
| [`v3_anchor/`](v3_anchor/README.md) | [Anchor Modeling](v3_anchor/ANCHOR.md) (6NF, table-per-attribute) | `build/anchor.db` | `archive/anchor_archive.db` |
| [`v3_hook/`](v3_hook/README.md) | [HOOK](v3_hook/HOOK.md) (source frames + key-set-qualified hooks) | `build/hook.db` | `archive/hook_archive.db` |
| [`v3_unified-star-schema/`](v3_unified-star-schema/README.md) | [Unified Star Schema](v3_unified-star-schema/USS.md) (Puppini bridge over an insert-only core) | `build/uss.db` | `archive/uss_archive.db` |
| [`v3_activity-schema/`](v3_activity-schema/README.md) | [Activity Schema](v3_activity-schema/ACTIVITY.md) (2.0: activity streams + temporal joins) | `build/activity.db` | `archive/activity_archive.db` |
| [`v3_metrics-mart/`](v3_metrics-mart/README.md) | [Metrics mart](v3_metrics-mart/METRICSMART.md) (3NF snowflake: resources, metric samples, calendar) | `build/metrics.db` | `archive/metrics_archive.db` |
| [`v3_one-big-table/`](v3_one-big-table/README.md) | [One Big Table](v3_one-big-table/OBT.md) (full-refresh over the log) | `build/obt.db` | `archive/obt_archive.db`; **is** the warehouse |

## The shared scenario

Three source systems (CRM customers, PIM products, OMS orders and order
lines) deliver on a realistic cadence: incremental windows, tombstones,
re-sent files, and periodic full snapshots.

| # | delivery | mode | what it proves |
|---|---|---|---|
| D0 | initial load, all feeds | FULL | baseline |
| D1 | CRM 14-day window: C001's email changed, C002 absent | INCREMENTAL | a 60-day-stale record must **not** look deleted |
| D2 | PIM full snapshot: SKU-1 repriced, SKU-3 missing | FULL | absence **does** delete a discontinued SKU |
| D3 | CRM window with explicit tombstone for C002 | INCREMENTAL | deletes travel as assertions, not absence |
| D4 | CRM window: C003 delivered twice, different extract times | INCREMENTAL | recency dedup (newest wins, not `MAX()`) |
| — | D1 re-sent under the same delivery id | — | load control skips it |
| D5 | CRM yearly reconciliation: only C001 remains | FULL | the safety net that catches unannounced deletes |

All ten enforce one rule, and it is the rule that separates working
incremental pipelines from quiet data loss:

> **Absence means DELETE only for a FULL delivery.** An INCREMENTAL
> delivery never infers a delete from absence. Deletes arrive as explicit
> tombstones, or a later FULL reconciliation finds them.

And all ten converge on the same end state: C001 is alive with
alice@newmail.com, C002 and C003 are deleted, and SKU-3 is discontinued.

<!-- compare:end-state:begin -->
```
inmon   : C001(alice@newmail.com)
kimball : C001(alice@newmail.com)
vault   : C001(alice@newmail.com)
focal   : C001(alice@newmail.com)
anchor  : C001(alice@newmail.com)
hook    : C001(alice@newmail.com)
uss     : C001(alice@newmail.com)
activity: C001(alice@newmail.com)
metrics : C001(alice@newmail.com)
obt     : C001(alice@newmail.com)
```
<!-- compare:end-state:end -->

`make compare` writes that block from each model's customer view, so
nobody types it by hand.

## Every warehouse model is a decision about who has to agree

Any of these models gets the right answer with SQLite, bash and a
Makefile, so correctness can't be what the debate is about.

What separates them is people. Each model decides when your organization
has to agree on what the data means, and which team does the agreeing.
You make that choice every time you pick a schema, whether you notice or
not.

### Agreement happens before the load, at the edge, or on read

Every model puts the hard conversation (what is a customer, what does
`'P'` mean) somewhere in the pipeline. I count three places.

Inmon, Focal, Anchor and the metrics mart settle it before the load.
Inmon conforms at ingest, so the EDW stores `PENDING` and the raw `'P'`
survives only in the archive. Focal translates on the way in through
`meta_value_map`. Anchor's knots are closed domains, which means an
order status nobody has defined fails the load outright. The metrics
mart does the same with a foreign key to its status code table, and it
needs a column before it can hold any new descriptive attribute. This
works when someone has the authority to make a definition stick. It
hurts when they change their mind: in the Inmon build a live rule change
can't touch rows already stored, and the only way back is a full rebuild
from the archive.

Kimball and the Unified Star Schema settle it at the edge, where data
meets its consumers. Kimball negotiates conformed dimensions per
business process, a much smaller agreement than an enterprise model. The
USS spends its design effort on the bridge so self-service users can't
double-count. In the demo the naive orders-to-lines join sums to 78.48
when the real total is 48.99.

Data Vault, HOOK, the Activity Schema and One Big Table leave it until
read time. Data Vault stores the raw `'P'` and decodes it in the mart
views. HOOK asks for a glossary of business concepts and the key sets
that say which system issued each key, and nothing more. The Activity
Schema asks for a catalog of verbs (`signed_up`, `placed_order`) and
keeps the raw `'P'` in `feature_json`. One Big Table asks for nothing at
all. They suit organizations where agreement isn't going to happen, as
long as someone downstream is ready to do the semantic work they skip.

### What each model makes you agree on, and who pays

| model | built for this problem | agreed before loading | who carries the cost | evidence |
|---|---|---|---|---|
| Inmon 3NF | Every department has its own version of the business | The whole entity model and its cleansing rules | The central EDW team, through change control and `ALTER TABLE` on populated history | Tested: conformed at ingest, and a rule change can't touch stored rows (Inmon M03). Argued: who carries the cost |
| Kimball | Users can't get answers and warehouse projects never finish | Conformed dimensions across business processes | Dimension governance. Audit moves to the archive, because facts update in place | Tested: the re-point restates the fact in place (Kimball M06). Argued: the rest |
| Data Vault 2.0 | Many sources, contested definitions, auditors | Business keys only | The business vault and mart builders, plus whoever writes the code generator | Shown: hubs hold business keys and nothing else. Argued: who carries the cost |
| Focal Point | Every new attribute waits on a DDL and ETL release | The concept model and value mappings | Metadata stewards. Every read pivots, and a rule change needs a rebuild | Tested: a rule change needs a rebuild (C12.1; Q9 in ANSWERS.md). Shown: every read pivots. Argued: the rest |
| Anchor | The model keeps changing and history can't break | Every attribute, with closed domains for codes | The generator team: 24 tables for what Focal holds in 4 | Tested: a code outside the knot fails the load (Anchor M08). Shown: 24 core tables. Argued: the rest |
| HOOK | Upfront modeling is too slow | A concept glossary and key sets | View authors. Key mapping is deferred, and frames follow source shapes | Tested: a hook from the wrong key set is flagged (HOOK M09). Shown: frames keep the source shape. Argued: the rest |
| Unified Star Schema | Self-service users get wrong totals | The bridge: stages, directions, loops | The bridge designers. History belongs to some other layer | Tested: the bridge stops the fan trap (USS M04). Shown: history comes from the core underneath (Q2, Q3, Q4 and Q7 in ANSWERS.md). Argued: the rest |
| Activity Schema | Every new question about behaviour waits on a new model | The activity catalog: which verbs exist and whose stream they belong to | Loader authors, who turn snapshots into events, and query authors, because current state is a LAST EVER query every time | Tested: every activity must be in the catalog (Activity M01). Shown: the loader diffs snapshots into events. Argued: the rest |
| Metrics mart | Many providers measure the same resources and nobody can put the numbers side by side | Resource types, the metric list and the code tables | The schema owners: every non-numeric attribute is a schema change. Descriptive attributes keep no history; the mart overwrites them | Tested: an unknown code fails the load (Metrics M11), and a new metric is a row with no DDL (Metrics M20). Shown: a new descriptive attribute needs an `ALTER`. Argued: the rest |
| One Big Table | Modeling costs more than it returns | Nothing | Every consumer, who rewrites the history query each time | Tested: unchanged snapshots are stored again (OBT M04). Argued: the rest |

Each row comes from that model's design notes, and the last column says
how far to trust it. **Tested** means an assertion or a mutation in that
model's suite proves it, named by its section. **Shown** means the code
makes it visible but nothing asserts it. **Argued** means it comes from
my experience and the model's own literature. Most of the "who carries
the cost" column is argued: a test suite written by one person can show
where a cost lands in the code, but not which team in your organization
ends up paying it.

## The same events, eight modeling schools

The two bookends, Inmon's close-and-insert versioning and OBT's
derive-everything-from-the-log, are covered in the next section.

| event | Focal Point | Data Vault 2.0 | Kimball | Anchor | HOOK | Unified Star Schema | Activity Schema | Metrics mart |
|---|---|---|---|---|---|---|---|---|
| attribute change | new version row **per atomic context** (narrow) | new satellite row (whole-row grain) | expire current dim row (**UPDATE**) + new SCD2 version | new row in **that attribute's own typed table** | new frame row, source shape kept | new core row; bridge re-derived | one `updated_<attr>` activity carrying only that attribute | a description: `UPDATE` in place. A number: a new `METRIC_SAMPLE` row |
| delete detected | closing row, `row_st='N'` | `'D'` row in a status-tracking satellite | deleted-marker version, `is_deleted=1`, last-known attrs carried | `DELETED` assertion in the **existence knot**; presence is data | `DELETE` frame row with a `delete_basis` | core `DELETE` row; member leaves its stage | a delete activity (`was_deleted`) with a `basis` | `res_status = 0`; the row and its samples stay |
| unchanged re-delivery | `NOCHANGE`; writes nothing | diff-string match; writes nothing | diff-string match; writes nothing | **restatement control**; writes nothing | diff-string match; writes nothing | `NOCHANGE` in the core; writes nothing | no difference from LAST EVER state; writes nothing | descriptions write nothing; a number observed again is a new sample |
| keys | sequence surrogates, reproduced by ordered replay | natural business keys | rowid surrogates, reproduced by ordered replay | per-anchor sequences, reproduced by ordered replay | key-set-qualified business keys (`CRM.CUST\|C001`) | `_key_<table>` from natural keys | source ids in `customer`; `activity_id` in load order, reproduced by ordered replay | integer surrogates in business-key order; `RES_ALIAS` resolves each provider's name |
| relationship | relationship loader (no re-point yet) | link + effectivity satellite | FK in the fact | historized tie | a second hook on the row | key on the bridge, propagated transitively | `link` plus who and when; no foreign keys | `parent_res`, or a group membership |
| business rule (P→PENDING) | applied **at ingest** (`meta_value_map`); archive + rebuild makes it retroactive | raw `'P'` stored; translated **on read** in the mart views | raw `'P'` in the archive; decode **dimension** (Type 1) | raw code resolved to a **knot**; label read at query | raw `'P'` in the frame; decoded **on read** in views | decoded **at refresh**; raw code kept on `orders.status_code` | raw `'P'` in `feature_json`; decoded **on read** | raw `'P'` behind a foreign key to a code table; decoded **on read** by a join |
| row mutation | never | never | dims expire, facts restate; the archive keeps it honest | never | never | core never; the USS layer is re-derived after every delivery | never; triggers refuse `UPDATE` and `DELETE` | resources update in place; a sample is overwritten only by a correction |

## What each one is best at showing

### Inmon 3NF: the control group, and better than its reputation

Inmon is the design every other model in the repo reacts to: a
time-variant normalized core with natural-key FKs, history by
close-and-insert on the entity tables, and conformance applied at ingest
(the EDW stores `PENDING`; the raw `'P'` survives only in the archive).
It passes the whole shared scenario, including versioning the re-pointed
order. But the suite makes the pain visible: queries follow the
*current* world unless you write the `v_order_as_recorded` range join,
the BETWEEN gymnastics every successor model exists to avoid. A live
rule change cannot touch stored rows, and schema evolution is `ALTER
TABLE` on populated history.

### Kimball: point-in-time answers from plain joins

Facts freeze the dimension version current at load. After C002 is
deleted, the star answers both `placed_by_at_purchase = 'Bob Jones'` and
`placed_by_current = NULL` with equi-joins. There's no history query and
no PIT construct. Its archive (Kimball's persistent staging area) is the
Focal archive pattern, reused as-is. The suite also shows the sharp
edge: ad-hoc Type 1 updates get reset by an archive rebuild unless they
live in the schema seed.

### Data Vault 2.0: presence and relationships as first-class facts

Status satellites answer "is it deleted?" directly, which is the
question Focal's ghost rows get wrong. The driving-key effectivity
satellite handles an order re-pointed to a different customer, something
Focal's relationship loader can't do yet. Hard rules in the vault, soft
rules on read: change the status decode and history follows with no
reload.

### Focal Point: schema evolution without DDL

A new attribute is a metadata row, not an `ALTER TABLE`. One generic
delta engine loads every entity, while most of the other demos
hand-write near-identical SQL per entity. That's manageable at three
entities. At thirty it means a code generator, and that's the burden
that pushed me off Data Vault. The archive makes the warehouse
disposable: `make rebuild` replays every delivery and reproduces every
surrogate key.

### Anchor: everything is data, everything is typed

Anchor uses 24 tables for what Focal holds in 4. Every attribute gets
its own table with a real column type. Presence is an existence knot, so
the ghost-row problem cannot happen here. The business key is itself an
attribute, and the historized tie handles the re-pointed order natively.

Anchor is Focal's philosophy at the opposite physical extreme. Its
loader is Focal's metadata loop retargeted at typed tables, which is why
the two unpivot the shared wide files into the same narrow key/value
rows. Anchor ships no loading doctrine of its own (the official tooling generates DDL and
triggers, not pipelines), so the shared discipline fills that gap. Knots
are closed domains: an unknown status code fails the load rather than
inventing a member.

### HOOK: Data Vault without the hub

Each source table stays a frame with `hk_<concept>` columns holding
key-set-qualified business keys (`CRM.CUST|C001`). Rows that carry the
same hook are about the same thing; that is the whole integration. The
re-pointed order is just a new order row, and the hub is a `GROUP BY`
view built only when someone asks. A delete is the latest frame row, so
there are no ghost rows. Like Anchor, HOOK prescribes a shape rather
than a loading discipline, so the shared rules fill the gap, and like
Focal, one registry-driven loader covers every frame.

### Unified Star Schema: no wrong totals

Every table gets a stage on the Puppini bridge carrying its own key and
every key it reaches, so measures never repeat, and the fan trap is gone
by construction. A table with no related rows still gets a stage, so
nothing drops out of a total either, and the chasm trap is gone too. The
USS is a presentation model, so the demo puts it on an insert-only core
(reusing HOOK's generic loader) and re-derives the bridge after every
delivery. When the order is re-pointed, the order *and its lines* move
to the new customer on the bridge.

### Activity Schema: model the verbs

The Activity Schema has no entities, facts or dimensions. It has two
streams of immutable activities (`signed_up`, `updated_email`,
`placed_order`, `was_ordered`) in one fixed set of columns, related by
who, what and when instead of foreign keys. "Who placed this order, as
they were then?" is a LAST BEFORE join on the order's own timestamp, and
the suite checks that the answer survives a later email change, a delete
and a re-point. Kimball gets the same answer by freezing a surrogate key
at load. Behavioural questions are short: days from signup to first
order is one query over one stream (`v_customer_journey`).

The cost comes from the corpus: these deliveries are state snapshots, so
the loader diffs each one against current state to manufacture events,
and most changes can only be stamped with the extract that revealed
them. SKU-1's `was_ordered` lands four days before its `added`. The spec
also says nothing about deletes, so the shared rule supplies them as
activities with a `basis`.

### Metrics mart: numbers get history, descriptions don't

The metrics mart is the one model here whose development and deployment
I was part of. It ran as an Enterprise Data Warehouse, collecting server
performance, automated call distribution and support ticketing data for
service level management reporting. It is 3NF with its codes snowflaked
out, and it has two kinds of table. `RES` holds every resource of every
type. `METRIC_SAMPLE` holds one observation per resource, metric,
provider and moment, so price and amount aren't columns anywhere, and
SKU-1's price history is two samples. `RES_ALIAS` turns whatever a
provider calls a resource into one `res_id`.

The cost is on the descriptive side. `RES` is current state, so C001's
new email overwrites the old one and the re-pointed order forgets its
first owner. Only the archive remembers. A new metric is a row, and the
suite adds one with no DDL. A new descriptive attribute is an `ALTER`.

It is also the only demo with a calendar. Planned events attach to
groups of resources, so a sample can be read next to what was planned
that day: SKU-1's price drop on 2026-03-02 sits beside a SPRING-SALE
promotion. The calendar arrives as a delivery of its own, after the
shared six.

### One Big Table: the null hypothesis

OBT has no model at all. The append-only log is the warehouse, and the
latest tables are one full-refresh recomputation over it. It passes
every shared scenario by deriving the mode-aware delete rule from the
log (a key is dead if its last mention is a tombstone or a later FULL
snapshot omitted it). Rebuild is trivial because nothing is incremental.
The suite asserts what that costs, too. There's no NOCHANGE suppression,
so unchanged snapshots get stored again forever. History means rewriting
the `LAG`-over-the-log query, and semantics live in views or nowhere. I
keep it runnable next to the other nine because it's the cleanest answer
I have to "what does modeling actually buy?"

## Every model picks a bottleneck

Read the last column of the cost table again. Every model has a
bottleneck, and the ten differ only in where they put it.

Inmon puts it on the central modeling team. Kimball puts it on whoever
governs the conformed dimensions. Data Vault and Anchor put it on the
automation team, because nobody hand-writes loaders for thirty entities
(I tried, which is how I ended up on Focal Point). Focal moves it to
whoever stewards the metadata. The USS puts it on the people who design
the bridge. The Activity Schema puts it on the loader that turns
snapshots into events, and on whoever keeps the activity catalog. The
metrics mart puts it on whoever owns the schema, for everything that
isn't a number. HOOK and One Big Table move it to the people writing
views, and in OBT every consumer is supposed to rewrite the same history
query correctly, every time. *(They won't.)*

So the useful question isn't which model is best. It's which team in
your organization has the authority and the skills to carry the
bottleneck. If the honest answer is nobody, pick a model that defers the
decision, and say out loud that you're deferring it.

## Shared engineering, deliberately

The demos are comparable because the plumbing is identical wherever the
model doesn't force a difference.

- **Capture raw, then apply.** In all ten, every delivery is archived
  verbatim, pre-dedup, to a durable append-only layer *before* any loader
  runs.
  The triggers have no unlock path. Re-archiving is `INSERT OR IGNORE`,
  and a reused delivery id with different content gets rejected.
- **Ingest and replay share one code path**: `apply_delivery.sh` in nine
  of the ten, and in OBT the one refresh over the log (`refresh_latest.sh`)
  that both ingest and rebuild run. A green rebuild test proves the real
  loaders, not a parallel replay path.
- **Load control.** A delivery is marked `COMPLETE` only after every
  loader succeeds. A crash leaves it retryable, with the staged rows in
  place as forensics. Success leaves the stage blank, except in Focal
  Point, which keeps the last delivery staged until the next one arrives
  (its per-delivery checks read it).
- **`make clean` never touches the durable layer.** Destroying raw
  history takes the explicit `clean-archive` target.
- **Mutation-tested suites** (DV 324, Metrics mart 261, Focal 218,
  Activity Schema 153, USS 145, Anchor 136, HOOK 134, Kimball 115, OBT
  100, Inmon 99 assertions, from [`VERIFY.md`](VERIFY.md)). I broke the
  FULL-absence guard, the replay ordering, the dedup tiebreaks, the
  restatement and idempotence guards, the tie guards, the OBT refresh,
  the Activity Schema's event-time and immutability guards, and the
  metrics mart's samples, type rules and calendar weeks on purpose, to
  prove the tests fail when they should. `make mutate` runs every
  breakage and writes [`MUTATIONS.md`](MUTATIONS.md). A green suite you
  haven't broken is a hypothesis.
- **One command, checked on every push.** `make all` runs `make verify`,
  `make mutate` and `make compare`, then fails if any result in
  [`VERIFY.md`](VERIFY.md), [`MUTATIONS.md`](MUTATIONS.md) or
  [`ANSWERS.md`](ANSWERS.md) differs from the committed copy
  (`tools/check_results.sh` compares results, never run times, commits or
  tool versions). CI runs it on Ubuntu and macOS with the stock `bash`;
  macOS uses its stock `sqlite3`, Ubuntu sqlite3 3.51.0 from sqlite.org
  (its own is older than 3.47). The three reports are kept as build
  artifacts.
- **One shared core in every suite.** Each suite runs the same 36 core
  assertions first, in fourteen sections with identical labels
  ([`tests/core_spec.tsv`](tests/core_spec.tsv)); each model supplies its
  own SQL, and its answers to the nine shared questions are in
  `tests/answers/`. Its own checks follow as MODEL sections. `make
  core-check` fails if any suite misses, repeats or reorders a core
  assertion; [`ALIGNMENT.md`](ALIGNMENT.md) maps every earlier assertion
  to its new place.
- **Known gaps are executable, not just documented.** A core assertion a
  model cannot pass today runs as an amber GAP line with the reason, and
  flips the suite red the moment it passes. The last two are closed:
  Focal's driving-key re-point (C13.1) and the metrics mart's re-observed
  price (C04.3), which now writes no sample. Every suite passes all 36
  core assertions.
- **One raw layer for all ten.** Every model loads the same six wide
  delivery files, byte for byte, and keeps them in the same archive
  layout (`loaded_files` + one `hist_*` table per source extract,
  append-only). Focal Point, Anchor and the metrics mart unpivot the wide
  rows into key/value rows in a second staging step.

## The experiment I haven't run yet

Every entity in the repo has exactly one source. OMS already uses CRM's
customer numbers, so HOOK's key-set mapping never fires, and I left out
Data Vault's same-as links because nothing needed them. The corpus also
has one path per relationship, so the USS never has to resolve a loop.
And no activity arrives before its customer is identified, so the
Activity Schema's `anonymous_customer_id` column stays empty. The
metrics mart's `RES_ALIAS` holds exactly one alias per resource.

The next delivery should be a second CRM from an acquisition, with its
own customer IDs and its own idea of what "active" means. Then count the
files each model makes you touch, and note where in the pipeline it
forces the decision.

If you've lived through that merger in production, tell me which model
survived it and which team ended up holding the bag.

## Requirements

bash, make, and sqlite3 3.47 or newer (Data Vault's triggers put an
expression in RAISE, which 3.47 added); the stock macOS binary works.
Each directory's `make help` lists its targets. Each has a standalone
README covering the design, the deviations and what that model gives up,
and a design-notes file that draws the cross-model comparison. Start
with the model you already believe in, run its suite, then run its
rival's.

Five companion essays take the comparison past load mechanics:

- [02-OPERATING-MODELS.md](docs/02-OPERATING-MODELS.md) maps the models onto
  Ross's operating models.
- [03-STUPIDITY-PARADOX.md](docs/03-STUPIDITY-PARADOX.md) reads them through
  Alvesson and Spicer's *The Stupidity Paradox*.
- [04-MARKET-EXHAUSTION.md](docs/04-MARKET-EXHAUSTION.md) asks why ten
  identical answers explain the market's fatigue with data.
- [05-THE-AGENTIC-TURN.md](docs/05-THE-AGENTIC-TURN.md) looks at what agents
  reprice, and what they don't.
- [06-WHAT-WANTS-TO-EMERGE.md](docs/06-WHAT-WANTS-TO-EMERGE.md) goes looking
  for a decision layer outside the data world.

[07-FUTURE-FUNCTIONALITY.md](docs/07-FUTURE-FUNCTIONALITY.md) ranks the
additions and tests I haven't built yet by how well they would separate
the ten models.
