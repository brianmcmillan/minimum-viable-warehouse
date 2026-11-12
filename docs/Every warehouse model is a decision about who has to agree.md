# Every warehouse model is a decision about who has to agree

Nov 9, 2026 · @Brian

## I ran the experiment

Data-modeling debates never end because nobody runs the experiment. So I ran it. [minimum-viable-warehouse](https://github.com/brianmcmillan/minimum-viable-warehouse) holds ten complete, working warehouses: an Inmon-style 3NF EDW, a Kimball star, Data Vault 2.0, Focal Point, an Anchor Modeling constellation, HOOK, a Unified Star Schema, an Activity Schema, a metrics mart and One Big Table (no model at all). All ten take the same six load files, enforce the same load semantics and return the same answers. Each one is SQLite, bash and Make, and the sqlite3 that ships with macOS is enough.

Any of these models gets the right answer, so correctness can't be what the debate is about. I wrote six pieces to work out what it is about. This post is the map.

## The models differ in who has to agree, and when

[One dataset, ten warehouses](../README.md) is the experiment itself: the shared scenario, the one delete rule all ten enforce, and what each model is best at showing.

One of the ten is personal. The metrics mart is the one model whose development and deployment I was part of. It ran as an Enterprise Data Warehouse, collecting server performance, automated call distribution and support ticketing data for service level management reporting. It keeps every number as a dated sample and overwrites everything else.

Every model puts the hard conversation (what is a customer, what does `'P'` mean) somewhere in the pipeline. Inmon, Focal, Anchor and the metrics mart settle it before the load. Kimball and the Unified Star Schema settle it at the edge, where data meets its consumers. Data Vault, HOOK, the Activity Schema and One Big Table leave it until read time.

Every model also picks a bottleneck. Inmon puts it on the central modeling team, Kimball on whoever governs the conformed dimensions, Data Vault and Anchor on the automation team, Focal on the metadata stewards. In One Big Table every consumer is supposed to rewrite the same history query correctly, every time. *(They won't.)*

So the useful question isn't which model is best. It's which team in your organization has the authority and the skills to carry the bottleneck.

## Your operating model should pick the warehouse

Most teams choose a model by taste. *Choose your warehouse model by your operating model* uses the 2×2 from Ross, Weill and Robertson's *Enterprise Architecture as Strategy* instead. Its two axes line up with the two capabilities these models differ on. Integration is identity: can the warehouse produce one customer across systems? Standardization, inverted, is schema evolution: what does a new attribute cost?

The quadrant errors are expensive and they don't show up at build time. Data Vault in a holding company is integration machinery with nothing to integrate. One Big Table in a firm whose units share customers under-builds the one thing that matters. My own move from Data Vault to Focal Point turns out to have been a quadrant correction.

## Every model is a way to postpone thinking

*Warehouse models are stupidity buffers* reads the ten through Alvesson and Spicer's *The Stupidity Paradox*. Their point is that not-thinking is useful. It buys coordination and speed, and the cost lands later on people who weren't in the room.

Each model cashes in on one kind of not-thinking and is spoiled by one kind. Data Vault lets you load without agreeing on meaning, and it decays when pattern compliance replaces the semantic work the deferral was supposed to buy time for. Kimball lives and dies by imitation. The Activity Schema gives you a stream of what customers did, which on snapshot feeds is a stream of what the extract noticed. The metrics mart remembers every number and forgets every description.

The raw layer is what makes any of this survivable. Deferral without an archive is debt. Deferral with one is an option.

## The market is tired for a good reason

Ten very different architectures return identical answers. So the choice among them was never what stood between an organization and better decisions. *The exhausted market and the ten warehouses* argues that the market spent two decades buying positions on a menu that prices the cost of maintaining truth, while expecting decision improvements the menu doesn't sell.

Count the directories in the repo. There are ten warehouses and no decision layer.

## Agents make writing free and checking scarce

An agent built these warehouses, their suites and these documents, and I directed and verified the work. *The agentic turn* covers what that changes. The labor argument against Data Vault and Anchor mostly dies. Agreement and accountability don't get any cheaper. And verification becomes the scarce activity: twice, mutation checks caught the agent's own tests passing for the wrong reason.

The models also differ in how well they keep an agent from making things up. Ask what `status='P'` means over One Big Table and a fluent consumer invents an answer. Over Anchor, the knot answers.

## The missing layer has older names

*What wants to emerge* goes looking outside the data world for the decision layer none of the ten directories contains. It climbs from statistical process control through cybernetics, Boyd's OODA loop and high-reliability organizations to stranger places. The traditions agree on loops, on sorting signal from noise, and on keeping the cost of having been wrong low. In this repo that cost has a stopwatch on it. It's `make rebuild`.

One input to that layer does exist. The metrics mart has a calendar of planned events, and it can show that a price fell during a promotion. A chart needs to know that before it calls the change a signal.

## What I haven't run yet

Every entity in the repo has exactly one source, so the identity machinery that separates these models never fires. The next delivery should be a second CRM from an acquisition, with its own customer IDs and its own idea of what "active" means. *What to build next* ranks that and seventeen other additions by how well they would tell the models apart.

Until then, run it yourself. You need bash, make and sqlite3. Start with the model you already believe in, run its suite, then run its rival's.

If you've lived through that merger in production, tell me which model survived it and which team ended up holding the bag.
