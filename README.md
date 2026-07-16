# One dataset, six warehouses

Data-modeling debates never end because nobody runs the experiment. So I
ran it. This repo holds six complete, working warehouses — an Inmon-style
3NF EDW, a Kimball star, Data Vault 2.0, Focal Point, an Anchor Modeling
constellation, and One Big Table (no model at all) — fed the same six
deliveries, enforcing the same load semantics, and returning the same
answers. Every difference you can observe between them is the model.
Never the data.

Together they span the whole argument: no model → normalize → dimensional
→ vault → attribute-grain, generic vs typed.

Each one is native SQLite, bash, and Make. No Python, no packages, no
server. The sqlite3 that ships with macOS is enough.

```bash
cd v3_inmon-3nf             && make demo && make test   # Inmon 3NF (control group)
cd v3_data-marts            && make demo && make test   # Kimball star
cd v3_datavault             && make demo && make test   # Data Vault 2.0
cd v3_focal-point && make demo && make test   # Focal Point
cd v3_anchor                && make demo && make test   # Anchor Modeling
cd v3_one-big-table         && make demo && make test   # One Big Table (null hypothesis)
```

| directory | model | derived layer | durable raw layer |
|---|---|---|---|
| [`v3_inmon-3nf/`](v3_inmon-3nf/README.md) | [Inmon time-variant 3NF EDW](v3_inmon-3nf/INMON.md) (natural keys) | `build/edw.db` | `archive/edw_archive.db` |
| [`v3_data-marts/`](v3_data-marts/README.md) | [Kimball star](v3_data-marts/DATAMART.md) (SCD2 + facts) | `build/datamart.db` | `psa/psa_datamart.db` (persistent staging) |
| [`v3_datavault/`](v3_datavault/README.md) | [Data Vault 2.0](v3_datavault/DATAVAULT.md) (natural keys) | `build/datavault.db` | the insert-only raw vault itself |
| [`v3_focal-point/`](v3_focal-point/README.md) | [Focal Point](v3_focal-point/FOCALPOINT.md) (metadata-driven, narrow/EAV) | `build/focal.db` | `archive/focal_archive.db` |
| [`v3_anchor/`](v3_anchor/README.md) | [Anchor Modeling](v3_anchor/ANCHOR.md) (6NF, table-per-attribute) | `build/anchor.db` | `archive/anchor_archive.db` |
| [`v3_one-big-table/`](v3_one-big-table/README.md) | [One Big Table](v3_one-big-table/OBT.md) (full-refresh over the log) | `build/obt.db` | `archive/obt_archive.db` — **is** the warehouse |

*Each **directory** links to that model's standalone README; each **model name** links to its design-notes companion — the in-depth cross-model comparison.*

<!--
  COMPANION-ESSAYS SECTION — commented out on 2026-07-14 because the five
  linked files are missing from the repo root (OPERATING-MODELS.md,
  STUPIDITY-PARADOX.md, MARKET-EXHAUSTION.md, WHAT-WANTS-TO-EMERGE.md,
  THE-AGENTIC-TURN.md). Hidden here to avoid broken links; restore the
  files and uncomment this block to bring it back verbatim.

If they all return the same answers, how do you choose? Five companion
essays work that question. Four keep every claim pointed at something you
can run in this repo. One is allowed to leave the evidence behind.

- [OPERATING-MODELS.md](OPERATING-MODELS.md) — Ross, Weill, and
  Robertson's operating-model 2×2. Your quadrant tells you which of the
  two machines (identity vs schema evolution) you will actually stress.
- [STUPIDITY-PARADOX.md](STUPIDITY-PARADOX.md) — Alvesson and Spicer's
  functional stupidity. Each model is a decision-timing device: which
  class of organizational not-thinking it monetizes, and which one
  corrupts it.
- [MARKET-EXHAUSTION.md](MARKET-EXHAUSTION.md) — the market's data
  fatigue, taken seriously. Six architectures answer *what is true*
  identically, so the choice among them prices truth maintenance. It
  never priced decision quality.
- [WHAT-WANTS-TO-EMERGE.md](WHAT-WANTS-TO-EMERGE.md) — the speculative
  one: seven guides from outside the data realm (SPC, cybernetics, Boyd,
  HRO, optionality, improvisation, predictive processing) for the
  operating model that doesn't have a clean name yet. Each comes with a
  probe you can build.
- [THE-AGENTIC-TURN.md](THE-AGENTIC-TURN.md) — how LLMs and autonomous
  agents reprice all four analyses. Authoring cost collapses,
  verification inverts, constraints become the agent's ground truth. An
  agent wrote it, inside the harness it describes. It says so.
-->
_Five companion essays that argued how to choose between the six models
once lived here; they're temporarily out while their files are missing._

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

All six enforce one rule, and it is the rule that separates working
incremental pipelines from quiet data loss:

> **Absence means DELETE only for a FULL delivery.** An INCREMENTAL
> delivery never infers a delete from absence. Deletes arrive as explicit
> tombstones, or a later FULL reconciliation finds them.

And all six converge on the same end state:

```
inmon   : C001(alice@newmail.com)
kimball : C001(alice@newmail.com)
vault   : C001(alice@newmail.com)
focal   : C001(alice@newmail.com) C002(null) C003(null)   <- ghost rows: see below
anchor  : C001(alice@newmail.com)
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
| business rule (P→PENDING) | applied **at ingest** (`meta_value_map`); archive + rebuild makes it retroactive | raw `'P'` stored; translated **on read** in the mart views | raw `'P'` in the PSA; decode **dimension** (Type 1) | raw code resolved to a **knot**; label read at query |
| row mutation | never | never | dims expire, facts restate — the PSA keeps it honest | never |

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
construct. Its Persistent Staging Area is the Focal archive pattern,
reused as-is. The suite also shows the sharp edge: ad-hoc Type 1 updates
get reset by a PSA rebuild unless they live in the schema seed.

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
in views or nowhere. Keeping it runnable next to the other five is the
cleanest answer to "what does modeling actually buy?"

## Shared engineering, deliberately

The demos are comparable because the plumbing is identical wherever the
model doesn't force a difference.

- **Capture raw, then apply.** Every delivery is archived verbatim,
  pre-dedup, to a durable append-only layer *before* any loader runs.
  The triggers have no unlock path. Re-archiving is `INSERT OR IGNORE`,
  and a reused delivery id with different content gets rejected.
- **Ingest and replay share one code path** (`apply_delivery.sh`). A
  green rebuild test proves the real loaders, not a parallel replay path.
- **Load control.** A delivery is marked `COMPLETE` only after every
  loader succeeds. A crash leaves it retryable, with the staged rows in
  place as forensics. Success leaves the stage blank.
- **`make clean` never touches the durable layer.** Destroying raw
  history takes the explicit `clean-archive` or `clean-psa` target.
- **Mutation-tested suites** (Focal 83+33, DV 77, Kimball 72, Anchor 72,
  Inmon 64, OBT 55 assertions). I broke the FULL-absence guard, the
  replay ordering, the dedup tiebreaks, the restatement and idempotence
  guards, the tie guards, and the OBT refresh on purpose, to prove the
  tests fail when they should. A green suite you haven't broken is a
  hypothesis.
- **Known gaps are executable, not just documented.** Focal's
  driving-key re-point gap runs as amber expected-failure assertions
  that print the suggested fix — and flip the suite red the moment the
  fix lands. See [`v3_focal-point/FOCALPOINT.md`](v3_focal-point/FOCALPOINT.md), "Known gap".
- **Byte-identical delivery files, pairwise.** DV, Kimball, Inmon, and
  OBT share the wide restatement; Focal and Anchor share the narrow
  key-value originals. One logical corpus, two physical shapes, six
  consumers.

## Requirements

bash, make, sqlite3. Any recent version; the stock macOS binary works.
Each directory's `make help` lists its targets, and each has its own
standalone README — the design, the deviations, and a plain accounting
of what that model gives up — plus a design-notes companion that draws
the cross-model comparison in full. Start with the model you already believe in,
run its suite, then run its rival's.
