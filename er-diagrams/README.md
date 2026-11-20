# ER diagrams

One set of entity-relationship diagrams per solution, generated from the
database each solution builds.

These diagrams are an optional extra, outside the ten warehouses. The
warehouses are SQLite, bash and Make only; the diagrams are built with
Python (`generate.py`), the Mermaid CLI and pypdf. No warehouse, suite
or `make` target needs them.

| Solution | Mermaid | PDF | Diagrams |
|---|---|---|---|
| Inmon 3NF EDW | [inmon-3nf.md](mermaid/inmon-3nf.md) | [pdf](pdf/inmon-3nf.pdf) | 4 |
| Kimball star | [data-marts.md](mermaid/data-marts.md) | [pdf](pdf/data-marts.pdf) | 4 |
| Data Vault 2.0 | [datavault.md](mermaid/datavault.md) | [pdf](pdf/datavault.pdf) | 4 |
| Focal Point | [focal-point.md](mermaid/focal-point.md) | [pdf](pdf/focal-point.pdf) | 4 |
| Anchor Modeling | [anchor.md](mermaid/anchor.md) | [pdf](pdf/anchor.pdf) | 7 |
| HOOK | [hook.md](mermaid/hook.md) | [pdf](pdf/hook.pdf) | 4 |
| Unified Star Schema | [unified-star-schema.md](mermaid/unified-star-schema.md) | [pdf](pdf/unified-star-schema.pdf) | 5 |
| Activity Schema | [activity-schema.md](mermaid/activity-schema.md) | [pdf](pdf/activity-schema.pdf) | 4 |
| Metrics mart | [metrics-mart.md](mermaid/metrics-mart.md) | [pdf](pdf/metrics-mart.pdf) | 8 |
| One Big Table | [one-big-table.md](mermaid/one-big-table.md) | [pdf](pdf/one-big-table.pdf) | 3 |

The files in `mermaid/` are Markdown with fenced `mermaid` blocks. GitHub
and VS Code draw them. Each PDF has one page per diagram, sized to the
diagram, so the wide ones (the Anchor and metrics mart overviews) need
zooming.

## Reading them

Each solution gets its core model first, then metadata, staging and the
raw archive. `PK` marks a primary-key column and `FK` a declared foreign
key. A solid line is a foreign key the schema declares. A dashed line is
a join the model intends but does not declare.

The dashed lines matter. Inmon, HOOK, the Unified Star Schema, One Big
Table and the Focal Point core declare no foreign keys, and SQLite
cannot report a relationship that is not declared. Those joins are
listed by hand in the `SOLUTIONS` table in `generate.py`. So are the
few joins the other models leave undeclared: Kimball's order ownership
(`dim_order_owner`, joined by business key), Data Vault's reference
table and computed satellite (`bv_order_status_bsat`, a view), and the
code columns of the metrics mart's `RES_HIST`. Focal Point's core shows
`meta_atomic_context` and `meta_relationship` with their keys only, so
every `type_key`, the existence contexts among them, has a line to where
it is defined. Activity Schema has no lines at all, because its streams
relate by customer, link and time and not by key.

## Regenerating

    make demo                              # in each solution, to build its database
    python3 er-diagrams/generate.py        # Mermaid only, standard library
    python3 er-diagrams/generate.py --pdf  # also the PDFs

The PDF step needs the Mermaid CLI (`npm install -g @mermaid-js/mermaid-cli`;
version 11 or 12) and `pip install pypdf`, installed for the same Python
that runs the script. A solution whose database is missing is skipped
with a message.

Columns, types and keys come from `PRAGMA table_info` and
`PRAGMA foreign_key_list`, so a schema change shows up on the next run.
A new undeclared join does not: add it to `SOLUTIONS`.
