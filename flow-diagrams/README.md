# Flow diagrams

How the repo runs, for a reader who has not opened a script. The
[ER diagrams](../er-diagrams/) show what each warehouse stores; these
show how a delivery becomes a warehouse, and how the suites, mutations
and answer matrix prove it.

These diagrams sit outside the ten warehouses. The Markdown files need
nothing to read; the PDFs are rendered with the Mermaid CLI. No warehouse
or suite needs them, but `make trace-check` (part of `make all`) reads
the two level-2 files, so a script added to a `make` target without a
diagram update fails `make all`.

| Diagram | Mermaid | PDF | Level |
|---|---|---|---|
| Build: how a delivery becomes a warehouse | [build.md](mermaid/build.md) | [pdf](pdf/build.pdf) | 1, conceptual |
| Prove: how the repo checks its own claims | [prove.md](mermaid/prove.md) | [pdf](pdf/prove.pdf) | 1, conceptual |
| Repo targets: the root Makefile and CI | [repo-targets.md](mermaid/repo-targets.md) | [pdf](pdf/repo-targets.pdf) | 2, traced |
| Model pipeline: one model's targets, and who does each step in all ten | [model-pipeline.md](mermaid/model-pipeline.md) | [pdf](pdf/model-pipeline.pdf) | 2, traced |

Level 1 draws the solution as a whole. The ten models appear as one box,
because they differ only inside it, and each node says what a stage does
rather than which file does it.

Level 2 draws the real call graph: the `make` targets, the scripts they
run and the schema files those read. It was found by tracing, not from
memory: `tools/trace_flows.sh` reads every Makefile, the CI workflow and
every script they call, and prints one indented tree per target.

## Reading them

**Build.** Read top to bottom. A delivery is staged exactly as sent, and
load control compares its file id and rows with the load manifest and
the archive before anything else happens. The load manifest holds one
row per delivery: file id, load order, batch time, row count and status.
The loader writes it, not the sender; in the code it is the archive's
`loaded_files` table. A file id names a delivery's
content: the same id with the same rows is skipped if it already
completed and retried if it only started; the same id with different
rows is rejected, and the stage is left as evidence. A delivery that
passes is archived wide, before any dedup, and only then reaches the
model-specific step, the dashed box. There Focal Point, Anchor and the
metrics mart first unpivot the wide rows into narrow key/value rows;
every model keeps the latest row per key and merges it into its own
tables, which the views read. The delete rule acts inside that step: a
tombstone always deletes, and a key missing from a delivery deletes only
when the delivery is FULL. Rebuild is the loop on the right: it empties
the model's tables and replays the archive, delivery by delivery in load
order, through the same step a new delivery takes.

**Prove.** Read from the bottom up. Every suite builds its own
throwaway warehouse and archive, runs the 36 core assertions (C01 to
C14, with the same ids and labels in all ten), then the model's own, and
ends with one summary. Three repo-wide runs use the suites: `make verify`
runs them as they are, `make mutate` runs them against code broken on
purpose, and `make compare` asks every model the nine shared questions
with the same queries the suites use. Each writes one report, and
`make manifest` writes a fourth, MANIFEST.md, listing every file in the
repo. `make all` runs the four, checks the level-2 flow diagrams
against the code, and fails if any result differs from the committed
copy, comparing results only, never run times or tool versions, so a
file added or removed without regenerating the manifest fails it too; CI runs `make all` on macOS and Ubuntu. `make core-check`
checks that every suite emits the core ids once each, in order; it is
run by hand and is not part of `make all`.

**Repo targets.** Read from the CI job on the left. `make all` runs
verify, mutate, compare, manifest and trace-check in turn, each even if
an earlier one failed, and then the results check. Each root target
names its script, and to its right is what that script does inside the
`v3_*` directories and the files it writes; dotted lines are files only
read, and the `tools/tree_state.sh` each run sources to report whether
it changed the work tree. A box inside `v3_*` is drawn once for all ten.
`make core-check` stands apart, because nothing runs it but you.

**Model pipeline.** The four subgraphs are one model's `make demo`,
`make rebuild`, `make test` and `make mutate`, with the stage names of
the two level-1 diagrams. `load_feed.sh` does stage, load control,
archive and, through `apply_delivery.sh`, the model-specific step, once
per delivery; `rebuild.sh` replays the archive through the same step.
The table under it names the file that does each step in each model,
and says where a model has a step the others lack: narrow staging in
Focal Point, Anchor and the metrics mart, the Data Vault business
vault, the Unified Star Schema bridge, the metrics mart's aggregates,
and One Big Table's single refresh in place of `apply_delivery.sh`.

## Tracing

    tools/trace_flows.sh                      # one indented tree per target
    tools/trace_flows.sh --check              # what make trace-check runs
    tools/trace_flows.sh --confirm v3_hook    # demo and test, traced for real
    tools/trace_flows.sh --orphans            # scripts no target runs

The trace is static: it reads each Makefile recipe and script for the
calls it makes (`./scripts/X.sh`, `"$(dirname "$0")/X.sh"`, `$PROJ/...`,
`schema/NN_name.sql`, `make -C "$PROJ" target` and the rest listed at the
top of the script) and follows them. `--confirm` checks it against a real
run: it copies one model to a scratch directory, runs the given targets
(`demo test` by default) with bash tracing on, and fails if the run
called a script or read a schema file that model's tree lacks. All ten
models pass for `demo`, `test`, `rebuild` and `mutate`. With bash 3.2 on
`PATH` it logs only each script's start, so files a script sources are
not checked.

`--check` fails if a script or schema file any target runs is named in
no level-2 diagram: a `v3_*` file must be named in its model's column of
the [model-pipeline](mermaid/model-pipeline.md) table, and a root script
in [repo-targets](mermaid/repo-targets.md). `--orphans` lists the
scripts no target runs; today that is only `flow-diagrams/render.sh`.

## Rendering

    bash flow-diagrams/render.sh

It writes one single-page PDF per file in `mermaid/`, and needs only bash
and the Mermaid CLI (`npm install -g @mermaid-js/mermaid-cli`; version 11
or 12). It stops with that install command if `mmdc` is missing. The
diagrams are written by hand: `make trace-check` catches a level-2
diagram that misses a script, but a change in what a stage does needs an
edit here and a re-render.
