# Activity Schema: model the verbs, not the nouns

Ahmed Elsamadisi's Activity Schema asks every other model in this repo a
different question: *why model nouns at all?* Customers, products and orders
are where the data lives; what the business asks about is what those
entities **did**, and in what order. So store activities, one stream per
entity type, and answer questions by relating activities in time.

Same wide deliveries as the DV, Kimball, Inmon, HOOK, USS and OBT demos,
byte-identical.

```bash
make demo     # fresh archive + the full delivery sequence + views
make rebuild  # regenerate the streams by replaying the raw layer
make test     # 123 assertions, mutation-checked
```

## The four ideas

- **An activity** is an entity doing something at a moment: `C001
  placed_order at 2026-02-01 10:00`. It never changes once written.
- **A stream** holds every activity for one entity type, in one fixed set
  of columns (`activity_id`, `ts`, `customer`, `activity`, `feature_json`,
  plus optional `anonymous_customer_id`, `revenue_impact`, `link`).
- **Ownership:** an activity stores only the metadata it is authoritative
  for. `updated_email` carries the email and nothing else.
- **Temporal relationships** replace joins: FIRST EVER, LAST EVER, LAST
  BEFORE, FIRST AFTER, and the in-between aggregates. Slowly changing data
  is LAST BEFORE at query time, not a versioned table.

## Where this implementation follows the spec, and where the shared discipline fills in

The spec defines the stream and the query relationships. It says nothing
about corrections or deletes, and it assumes event sources, so the shared
rules fill the gaps, as they did for Anchor and HOOK:

| concern | Activity Schema 2.0 | this demo adds |
|---|---|---|
| storage | one stream per entity type, fixed columns | `customer_stream` and `product_stream`, spec columns + `_seq`, `_load_ts`, `_record_source` |
| immutability | activities should never change | triggers that refuse `UPDATE` and `DELETE` |
| source shape | events | **state snapshots**, diffed against LAST EVER state to derive events |
| change capture | a change is a new activity | one `updated_<attr>` per changed attribute; NOCHANGE writes nothing |
| deletes, corrections | **not addressed** | the shared rule: tombstone always, absence only under FULL, as delete activities with a `basis` |
| `ts` | when the activity happened | event time where the source has it, observed (extract) time otherwise |
| non-customer things | one stream per entity | orders as `link`-ed customer activities; order lines as `was_ordered` product activities |
| entity tables | optional | omitted: current state is a view over the streams |
| raw retention | not covered | a separate verbatim archive, because the streams drop restatements and dedup losers |
| business rules | downstream | `ref_oms_order_status` decoded on read |

## The same events, compared

| event | Activity Schema | HOOK | Data Vault 2.0 | Kimball | OBT |
|---|---|---|---|---|---|
| attribute change | `updated_<attr>` activity, that attribute only | new frame row | new satellite row | expire + new SCD2 version | nothing stored; derived from the log |
| delete | delete activity + `basis` | `DELETE` frame row | `'D'` status-satellite row | deleted-marker version | derived from the log |
| unchanged re-delivery | writes nothing | writes nothing | writes nothing | writes nothing | **stored again** |
| relationship | `link` + who + when | a second hook on the row | link + effectivity satellite | FK in the fact | a column |
| re-point (D6) | `order_reassigned` in the new owner's stream | new order row | new link + effectivity flip | fact restated | derived |
| "as at purchase" | LAST BEFORE on event time | as-of on load time | satellite as-of (no PIT table here) | frozen surrogate key | `LAG` over the log |
| current state | LAST EVER (view) | latest row (view) | latest satellite (view) | `is_current` row | full refresh |
| row mutation | never | never | never | dims expire, facts restate | never |

## What the demo shows

**Point-in-time is a join on time, not a stored key.** Kimball answers "who
placed this order, as they were then?" by freezing a surrogate key at load.
Here `v_order_at_purchase` takes the newest profile activity strictly before
the order's `placed_at`. It survives a later email change, the customer's
deletion, and a re-point, and the suite checks all three.

**Behavioural questions are short.** "Days from signup to first order" and
"did the customer change email after ordering?" are FIRST EVER and FIRST
AFTER over one stream (`v_customer_journey`). The same questions against a
star or a vault need date logic across several tables.

**Immutability makes history free.** Nothing is ever closed, expired or
restated, so every past state is still there without validity windows.
Deleted customers keep their whole journey.

**No ghost rows.** A delete is the newest lifecycle activity, so LAST EVER
drops the subject from the business views by construction.

## What it costs

- **The source shape works against it.** Every delivery here is a state
  snapshot, so the loader spends its effort diffing against LAST EVER state
  to manufacture events. With real event sources (CDC, clickstream, an
  OMS event log) that layer would mostly disappear. The demo is honest about
  the corpus it was given.
- **Observed time is not event time.** Most `updated_*` activities can only
  be stamped with the extract that revealed them, and the first-observed
  profile is attributed to signup. LAST BEFORE is exactly as good as those
  timestamps. SKU-1's `was_ordered` landing before its `added` is the same
  effect, visible in the data.
- **Orders don't fit.** The model is customer-centric. Order state is
  assembled from activities by `link`, and the re-point needs its own
  activity because `placed_order` can't change.
- **Everything is a query.** Current state is LAST EVER per attribute over
  the whole stream, every time. Production implementations add entity
  tables or materializations, which is the mutation this demo avoids.
- **`feature_json` is untyped.** The schema enforces nothing about attribute
  values, unlike Anchor's typed attribute tables.
- **The delete rules are borrowed.** The spec's silence on corrections and
  deletes means a team adopting it has to bring its own, as this demo does.

## Layout

```
schema/01_stage.sql          wide stage L1 (shared shape) + L2 recency-dedup views
schema/02_archive.sql        raw layer: append-only wide history + manifest
schema/03_activity.sql       the two streams, immutability triggers, activity catalog, LAST EVER state views
schema/04_views.sql          business views, LAST BEFORE / FIRST EVER / FIRST AFTER views
scripts/load_activities.sh   snapshot -> activities: change detection + the shared delete rule
tests/run_tests.sh           123 assertions
```
