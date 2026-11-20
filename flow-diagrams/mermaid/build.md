# Build: how a delivery becomes a warehouse

Level 1, conceptual. One delivery's path through any of the ten models,
and the rebuild that replays the archive through the same step. The ten
models differ only inside the dashed box. See the
[README](../README.md) for how to read it.

```mermaid
flowchart TD
  D["Shared wide deliveries<br/>D0 to D5, the same bytes for all ten models,<br/>plus the re-point the suites and compare add"]
  S["Stage<br/>the delivery's rows, exactly as sent"]
  LC{"Load control<br/>has this file id been seen?"}
  MF[("load_manifest<br/>one row per file id: load order, batch time,<br/>row count, STARTED or COMPLETE")]
  SK["Skip<br/>same id, same rows, already COMPLETE"]
  RJ["Reject and stop<br/>same id, different row count or rows;<br/>the stage is left for inspection"]
  A[("Wide archive, insert-only<br/>every row as delivered, before dedup")]
  subgraph M["Model-specific step: one box for all ten models"]
    N["Focal Point, Anchor and the metrics mart only:<br/>unpivot the wide rows into narrow key/value rows"]
    L["Keep the latest row per key,<br/>then merge into the model's tables"]
    DR{{"Delete rule<br/>a tombstone always deletes;<br/>a key absent from the delivery<br/>deletes only if the delivery is FULL"}}
  end
  T[("The model's tables")]
  V["Views<br/>what every query reads"]
  C["Mark the load_manifest row COMPLETE, clear the stage<br/>a failure leaves the stage as evidence"]
  RB["Rebuild<br/>recreate the model's tables empty,<br/>replay every archived delivery in load order"]

  D --> S --> LC
  LC <-. "checks and records" .-> MF
  LC -- "already COMPLETE" --> SK
  LC -- "content differs" --> RJ
  LC -- "new id, or a retry of a STARTED one" --> A
  A --> N --> L
  L --- DR
  L --> T --> V
  L --> C
  A -- "rebuild" --> RB
  RB -- "the same step as a new delivery" --> N

  style M stroke-dasharray: 6 4
```
