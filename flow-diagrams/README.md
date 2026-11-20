# Flow diagrams

How the repo runs, for a reader who has not opened a script. The
[ER diagrams](../er-diagrams/) show what each warehouse stores; these
show how a delivery becomes a warehouse, and how the suites, mutations
and answer matrix prove it.

These diagrams are an optional extra, outside the ten warehouses. The
Markdown files need nothing; the PDFs are rendered with the Mermaid CLI.
No warehouse, suite or `make` target needs them.

| Diagram | Mermaid | PDF | Level |
|---|---|---|---|
| Build: how a delivery becomes a warehouse | [build.md](mermaid/build.md) | [pdf](pdf/build.pdf) | 1, conceptual |
| Prove: how the repo checks its own claims | [prove.md](mermaid/prove.md) | [pdf](pdf/prove.pdf) | 1, conceptual |

Level 1 draws the solution as a whole. The ten models appear as one box,
because they differ only inside it, and each node says what a stage does
rather than which file does it.

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
repo. `make all` runs the four and fails if any result differs from the
committed copy, comparing results only, never run times or tool
versions, so a file added or removed without regenerating the manifest
fails it too; CI runs `make all` on macOS and Ubuntu. `make core-check`
checks that every suite emits the core ids once each, in order; it is
run by hand and is not part of `make all`.

## Rendering

    bash flow-diagrams/render.sh

It writes one single-page PDF per file in `mermaid/`, and needs only bash
and the Mermaid CLI (`npm install -g @mermaid-js/mermaid-cli`; version 11
or 12). It stops with that install command if `mmdc` is missing. The
diagrams are written by hand, so a change to how the repo runs needs an
edit here.
