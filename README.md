# One dataset, nine warehouses

Data-modeling debates never end because nobody runs the experiment. So I
ran it. This repo holds nine complete, working warehouses — an Inmon-style
3NF EDW, a Kimball star, Data Vault 2.0, Focal Point, an Anchor Modeling
constellation, HOOK, a Unified Star Schema, an Activity Schema, and One Big
Table (no model at all) — fed the same six load files, enforcing the same load semantics,
and returning the same answers. The only difference between them is the model.

Together they span the whole argument: no model → normalize → dimensional
→ vault → hooks-only → attribute-grain, generic vs typed → activities
instead of entities — plus a presentation layer that makes any join safe.

Each one is native SQLite, bash, and Make. No Python, no packages, no
server. The sqlite3 that ships with macOS is enough.

```bash
cd v3_inmon-3nf             && make demo && make test   # Inmon 3NF (control group)
cd v3_data-marts            && make demo && make test   # Kimball star
cd v3_datavault             && make demo && make test   # Data Vault 2.0
cd v3_focal-point           && make demo && make test   # Focal Point
cd v3_anchor                && make demo && make test   # Anchor Modeling
cd v3_hook                  && make demo && make test   # HOOK
cd v3_unified-star-schema   && make demo && make test   # Unified Star Schema
cd v3_activity-schema       && make demo && make test   # Activity Schema
cd v3_one-big-table         && make demo && make test   # One Big Table (null hypothesis)
```

| directory | model | derived layer | durable raw layer |
|---|---|---|---|
| [`v3_inmon-3nf/`](v3_inmon-3nf/README.md) | [Inmon time-variant 3NF EDW](v3_inmon-3nf/INMON.md) (natural keys) | `build/edw.db` | `archive/edw_archive.db` |
| [`v3_data-marts/`](v3_data-marts/README.md) | [Kimball star](v3_data-marts/DATAMART.md) (SCD2 + facts) | `build/datamart.db` | `archive/datamart_archive.db` |
| [`v3_datavault/`](v3_datavault/README.md) | [Data Vault 2.0](v3_datavault/DATAVAULT.md) (natural keys) | `build/datavault.db` | the insert-only raw vault itself |
| [`v3_focal-point/`](v3_focal-point/README.md) | [Focal Point](v3_focal-point/FOCALPOINT.md) (metadata-driven, narrow/EAV) | `build/focal.db` | `archive/focal_archive.db` |
| [`v3_anchor/`](v3_anchor/README.md) | [Anchor Modeling](v3_anchor/ANCHOR.md) (6NF, table-per-attribute) | `build/anchor.db` | `archive/anchor_archive.db` |
| [`v3_hook/`](v3_hook/README.md) | [HOOK](v3_hook/HOOK.md) (frames + key-set-qualified hooks, no hubs or links) | `build/hook.db` | `archive/hook_archive.db` |
| [`v3_unified-star-schema/`](v3_unified-star-schema/README.md) | [Unified Star Schema](v3_unified-star-schema/USS.md) (Puppini bridge over an insert-only core) | `build/uss.db` | `archive/uss_archive.db` |
| [`v3_activity-schema/`](v3_activity-schema/README.md) | [Activity Schema](v3_activity-schema/ACTIVITY.md) (2.0: activity streams + temporal joins) | `build/activity.db` | `archive/activity_archive.db` |
| [`v3_one-big-table/`](v3_one-big-table/README.md) | [One Big Table](v3_one-big-table/OBT.md) (full-refresh over the log) | `build/obt.db` | `archive/obt_archive.db` — **is** the warehouse |

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

All nine enforce one rule, and it is the rule that separates working
incremental pipelines from quiet data loss:

> **Absence means DELETE only for a FULL delivery.** An INCREMENTAL
> delivery never infers a delete from absence. Deletes arrive as explicit
> tombstones, or a later FULL reconciliation finds them.

And all nine converge on the same end state:

```
inmon   : C001(alice@newmail.com)
kimball : C001(alice@newmail.com)
vault   : C001(alice@newmail.com)
focal   : C001(alice@newmail.com) C002(null) C003(null)   <- ghost rows: see below
anchor  : C001(alice@newmail.com)
hook    : C001(alice@newmail.com)
uss     : C001(alice@newmail.com)
activity: C001(alice@newmail.com)
obt     : C001(alice@newmail.com)
```

## The same events, four modeling schools

The two bookends — Inmon's close-and-insert versioning and OBT's
derive-everything-from-the-log — get their own section below.

| event | Focal Point | Data Vault 2.0 | Kimball | Anchor |
|---|---|---|---|---|
| attribute change | new version row **per atomic context** (narrow) | new satellite row (whole-row grain) | expire current dim row (**UPDATE**) + new SCD2 version | new row in **that attribute's own typed table** |
| delete detected | closing row, `row_st='N'` | `'D'` row in a status-tracking satellite | deleted-marker version, `is_deleted=1`, last-known attrs carried | `DELETED` assertion in the **existence knot** — presence is data |
| unchanged re-delivery | `NOCHANGE` — writes nothing | diff-string match — writes nothing | diff-string match — writes nothing | **restatement control** — writes nothing |
| keys | sequence surrogates, reproduced by ordered replay | natural business keys | rowid surrogates, reproduced by ordered replay | per-anchor sequences, reproduced by ordered replay |
| business rule (P→PENDING) | applied **at ingest** (`meta_value_map`); archive + rebuild makes it retroactive | raw `'P'` stored; translated **on read** in the mart views | raw `'P'` in the archive; decode **dimension** (Type 1) | raw code resolved to a **knot**; label read at query |
| row mutation | never | never | dims expire, facts restate — the archive keeps it honest | never |

## What each demo is best at showing

**Focal Point: schema evolution without DDL.** A new attribute is a
metadata row, not an `ALTER TABLE`. One generic delta engine loads every
entity. The other demos hand-write near-identical SQL per entity — fine
at three entities, and at thirty it becomes the code-generator burden
that pushed me off Data Vault in the first place. The archive makes the
warehouse disposable: `make rebuild` replays every delivery and
reproduces every surrogate key.

**Data Vault 2.0: presence and relationships as first-class facts.**
Status satellites answer "is it deleted?" directly. Focal's `v_customer`
still shows deleted customers as ghost rows — a known gap, documented and
tested. The driving-key effectivity satellite handles an order re-pointed
to a different customer, which Focal's relationship loader currently
cannot. Hard rules in the vault, soft rules on read: change the status
decode and history follows with no reload.

**Kimball: point-in-time answers from plain joins.** Facts freeze the
dimension version current at load. After C002 is deleted, the star
answers both `placed_by_at_purchase = 'Bob Jones'` and
`placed_by_current = NULL` with equi-joins — no history query, no PIT
construct. Its archive (Kimball's persistent staging area) is the Focal archive
pattern, reused as-is. The suite also shows the sharp edge: ad-hoc Type 1 updates
get reset by an archive rebuild unless they live in the schema seed.

**Anchor: everything is data, everything is typed.** 24 tables for what
Focal holds in 4. Every attribute gets its own table with a real column
type. Presence is an existence knot, so the ghost-row problem cannot
happen here. The business key is itself an attribute, and the historized
tie handles the re-pointed order natively. Anchor is Focal's philosophy
at the opposite physical extreme — its loader is literally Focal's
metadata loop retargeted at typed tables, which is why the two share
byte-identical narrow delivery files. Anchor ships no loading doctrine of
its own (the official tooling generates DDL and triggers, not
pipelines), so the shared discipline fills that gap. Knots are closed
domains: an unknown status code fails the load rather than inventing a
member.

**HOOK: Data Vault without the hub.** Keep each source table as a frame,
add `hk_<concept>` columns holding key-set-qualified business keys
(`CRM.CUST|C001`), and stop there. A relationship is a second hook on the
row that asserts it, so the re-pointed order is just a new order row. The
hub is a `GROUP BY` view, built only when someone asks. Because frames are
source-aligned, one registry-driven loader handles every frame, which is
the automation Focal gets from going narrow, here with wide, typed tables.
The bill: integration is exact matching on key sets, so mapping work is
deferred, not removed, and all semantics run on read.

**Unified Star Schema: no wrong totals.** Puppini's bridge is a
presentation layer, so here it sits on an insert-only core. Every table
loses its foreign keys and gets a stage on `_bridge` carrying its own key
and every key it reaches many-to-one, so an order line knows its
customer. Measures sit only on their own stage: the naive orders-to-lines
join sums to 78.48, the bridge to the true 48.99. Order-less customers
keep their row, so nothing drops out. The bill: no history of its own, a
bridge that grows with every table, and a materialised layer that needs a
refresh when a rule changes.

**Activity Schema: model the verbs.** No entities, no facts, no
dimensions: two streams of immutable activities (`signed_up`,
`updated_email`, `placed_order`, `was_ordered`) with a fixed set of
columns, related by who, what and when instead of foreign keys. "Who placed
this order, as they were then?" is a LAST BEFORE join on the order's own
timestamp, and it survives a later email change, a delete and a re-point.
Behavioural questions (days from signup to first order, what changed after
it) are one stream query. The bill: these deliveries are state snapshots,
so the loader diffs each one against current state to manufacture events,
most changes can only be stamped when they were *observed*, and the spec is
silent on deletes, so the shared rule supplies them.

## The bookends

**Inmon 3NF: the control group.** The design every other leg reacts to. A
time-variant normalized core with natural-key FKs, history via
close-and-insert on the entity tables, conformance applied at ingest (the
EDW stores `PENDING`; the raw `'P'` survives only in the archive). It is
better than its reputation. It passes the whole shared scenario,
including versioning the re-pointed order. But the suite makes the pain
visible: queries follow the *current* world unless you write the
`v_order_as_recorded` range join — the BETWEEN gymnastics every successor
model exists to avoid — a live rule change cannot touch stored rows, and
schema evolution is `ALTER TABLE` on populated history.

**One Big Table: the null hypothesis.** No model at all. The append-only
log is the warehouse, and the latest tables are one full-refresh
recomputation over it. It passes every shared scenario — the mode-aware
delete rule is derived from the log (a key is dead if its last mention is
a tombstone or a later FULL snapshot omitted it) — and rebuild is trivial
because nothing is incremental. The bill is asserted, not hinted: no
NOCHANGE suppression, so unchanged snapshots get stored again forever;
history only by rewriting the `LAG`-over-the-log query; semantics living
in views or nowhere. Keeping it runnable next to the other eight is the
cleanest answer to "what does modeling actually buy?"

## Shared engineering, deliberately

The demos are comparable because the plumbing is identical wherever the
model doesn't force a difference.

- **Capture raw, then apply.** Every model except Data Vault archives each
  delivery verbatim, pre-dedup, to a durable append-only layer *before* any
  loader runs. (Data Vault's insert-only raw vault is its history; its
  delivery files are the only replayable input.)
  The triggers have no unlock path. Re-archiving is `INSERT OR IGNORE`,
  and a reused delivery id with different content gets rejected.
- **Ingest and replay share one code path** (`apply_delivery.sh`) in every
  model that replays. A green rebuild test proves the real loaders, not a
  parallel replay path. OBT has nothing to replay (rebuild is one full
  refresh over the log).
- **Load control.** A delivery is marked `COMPLETE` only after every
  loader succeeds. A crash leaves it retryable, with the staged rows in
  place as forensics. Success leaves the stage blank.
- **`make clean` never touches the durable layer.** Destroying raw
  history takes the explicit `clean-archive` target. (Data Vault has no
  separate durable layer: `make clean` deletes the vault, and `make demo`
  rebuilds it from the delivery files.)
- **Mutation-tested suites** (Focal 83+33, Activity 123, USS 113, HOOK 99,
  DV 77, Kimball 72, Anchor 72, Inmon 64, OBT 55 assertions). I broke the FULL-absence guard, the
  replay ordering, the dedup tiebreaks, the restatement and idempotence
  guards, the tie guards, the OBT refresh, and the activity loader's
  event-time and immutability guarantees on purpose, to prove the
  tests fail when they should. A green suite you haven't broken is a
  hypothesis.
- **Known gaps are executable, not just documented.** Focal's
  driving-key re-point gap runs as amber expected-failure assertions
  that print the suggested fix — and flip the suite red the moment the
  fix lands. See [`v3_focal-point/FOCALPOINT.md`](v3_focal-point/FOCALPOINT.md), "Known gap".
- **Byte-identical delivery files, pairwise.** DV, Kimball, Inmon, HOOK,
  USS, Activity Schema and OBT share the wide restatement; Focal and Anchor
  share the narrow key-value originals. One logical corpus, two physical
  shapes, nine consumers.
- **Archives aligned by shape.** The six wide-shape archives (Inmon,
  Kimball, HOOK, USS, Activity Schema, OBT) share one layout (`loaded_files` + `hist_*`)
  and the archive files in the repo are byte-identical. Focal and Anchor
  share the narrow `source_landing_history` layout. No archive carries
  secondary indexes; at this data volume they add nothing. Re-running
  `make demo` re-stamps the `loaded_at`/`archived_at` columns, so a fresh
  archive matches its siblings in everything except those timestamps.

## Requirements

bash, make, sqlite3. Any recent version; the stock macOS binary works.
Each directory's `make help` lists its targets, and each has its own
standalone README — the design, the deviations, and a plain accounting
of what that model gives up — plus a design-notes companion that draws
the cross-model comparison in full. Start with the model you already believe in,
run its suite, then run its rival's.
