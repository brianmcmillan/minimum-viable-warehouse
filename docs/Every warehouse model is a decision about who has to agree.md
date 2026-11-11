# Every warehouse model is a decision about who has to agree

Nov 9, 2026 · @Brian

## Eight warehouses, one answer

I built eight data warehouses on the same six load files: Inmon 3NF, a Kimball star, Data Vault 2.0, Focal Point, Anchor, HOOK, a Unified Star Schema and One Big Table. They all land in the same place. C001 is alive with alice@newmail.com, C002 and C003 are deleted, and SKU-3 is discontinued. (Focal still lists the deleted customers as ghost rows, and I kept that gap in its test suite on purpose.)

So the modeling argument was never about getting the right answer. Any of these can get there with SQLite, bash and a Makefile.

What the models really disagree about is people. Each one decides when your organization has to agree on what the data means, and which team does the work of agreeing. That's an org chart decision wearing a schema.

## Agreement happens before the load, at the edge, or on read

Every model puts the hard conversation (what is a customer, what does `'P'` mean) somewhere in the pipeline. I count three places.

The first is before the load. Inmon conforms at ingest, so the EDW stores `PENDING` and the raw `'P'` survives only in the archive. Focal translates on the way in through `meta_value_map`. Anchor's knots are closed domains, which means an order status nobody has defined fails the load outright. This works when someone has the authority to make a definition stick. It hurts when they change their mind: in my Inmon build a live rule change can't touch rows already stored, and the only way back is a full rebuild from the archive.

The second is at the edge, where data meets its consumers. Kimball negotiates conformed dimensions per business process, a much smaller agreement than an enterprise model. The Unified Star Schema spends its design effort on the bridge so self-service users can't double-count. In my demo the naive orders-to-lines join sums to 78.48 when the real total is 48.99.

The third is on read. Data Vault stores the raw `'P'` and decodes it in the mart views. HOOK asks for a glossary of business concepts and the key sets that say which system issued each key, and nothing more. One Big Table asks for nothing at all. These suit organizations where agreement isn't going to happen. But they don't remove the semantic work. They hand it to whoever builds downstream.

## What each model makes you agree on, and who pays

| Model | Built for this problem | Agreed before loading | Who carries the cost |
| --- | --- | --- | --- |
| Inmon 3NF | Every department has its own version of the business | The whole entity model and its cleansing rules | The central EDW team, through change control and `ALTER TABLE` on populated history |
| Kimball | Users can't get answers and warehouse projects never finish | Conformed dimensions across business processes | Dimension governance. Audit moves to the PSA, because facts update in place |
| Data Vault 2.0 | Many sources, contested definitions, auditors | Business keys only | The business vault and mart builders, plus whoever writes the code generator |
| Focal Point | Every new attribute waits on a DDL and ETL release | The concept model and value mappings | Metadata stewards. Every read pivots, and a rule change needs a rebuild |
| Anchor | The model keeps changing and history can't break | Every attribute, with closed domains for codes | The generator team: 24 tables for what Focal holds in 4 |
| HOOK | Upfront modeling is too slow | A concept glossary and key sets | View authors. Key mapping is deferred, and frames follow source shapes |
| Unified Star Schema | Self-service users get wrong totals | The bridge: stages, directions, loops | The bridge designers. History belongs to some other layer |
| One Big Table | Modeling costs more than it returns | Nothing | Every consumer, who rewrites the history query each time |

Each row comes from that model's design notes in [minimum-viable-warehouse](https://github.com/brianmcmillan/minimum-viable-warehouse). Run `make test` in any directory to check my claims.

## Every model picks a bottleneck

Read the last column again. None of the eight gets rid of the bottleneck; each one moves it somewhere.

Inmon puts it on the central modeling team. Kimball puts it on whoever governs the conformed dimensions. Data Vault and Anchor put it on the automation team, because nobody hand-writes loaders for thirty entities. I know that one personally: the per-entity repetition in my Data Vault loaders is what pushed me to Focal Point in the first place. Focal moves it to whoever stewards the metadata. HOOK and One Big Table move it to the people writing views, and in OBT every consumer is supposed to rewrite the same history query correctly, every time. *(They won't.)*

So the useful question isn't which model is best. It's which team in your organization has the authority and the skills to carry the bottleneck. If the honest answer is nobody, pick a model that defers the decision, and say out loud that you're deferring it.

## The experiment I haven't run yet

My repo has a weakness, and it's the one that matters most for this argument. Every entity has exactly one source. OMS already uses CRM's customer numbers, so HOOK's key-set mapping never fires, and I left out Data Vault's same-as links because nothing needed them. The eight warehouses agree on load mechanics. None of them has been asked to settle a disagreement.

The next delivery should be a second CRM from an acquisition, with its own customer IDs and its own idea of what "active" means. Then count the files each model makes you touch, and note where in the pipeline it forces the decision.

If you've lived through that merger in production, tell me which model survived it and which team ended up holding the bag.
