# Model pipeline: one model's make targets, traced

Level 2, traced. One generic model: what `make demo`, `make rebuild`,
`make test` and `make mutate` run, using the stage names of
[build.md](build.md) and [prove.md](prove.md). The table below names the
file that does each step in each of the ten models. Found by
`tools/trace_flows.sh` (`--confirm` checks a model's tree against a
traced real run); `make trace-check` fails if a script or schema file a
target runs is missing from that model's column. See the
[README](../README.md) for how to read it.

```mermaid
flowchart TB
  subgraph DEMO["make demo"]
    direction TB
    D0["remove archive/"]
    D1["init_db.sh<br/>create the archive (kept if present)<br/>and the model's tables from schema/*.sql"]
    subgraph LF["load_feed.sh, once per delivery D0 to D5"]
      direction TB
      D2["Stage<br/>the delivery's rows, as sent"]
      D3["Load control<br/>against the load_manifest (loaded_files)"]
      D4["Wide archive<br/>insert-only hist_* rows"]
      D5["narrow staging, three models only<br/>stage_narrow.sh"]
      D6["Model-specific step<br/>apply_delivery.sh and the model's loaders<br/>(One Big Table: refresh_latest.sh instead);<br/>the delete rule acts here"]
      D7["Mark COMPLETE, clear the stage"]
    end
    D8["query.sh<br/>Views"]
    D0 --> D1 --> D2 --> D3 --> D4 --> D5 --> D6 --> D7 --> D8
  end

  subgraph REB["make rebuild"]
    direction TB
    R1["rebuild.sh"]
    R2["init_db.sh<br/>the model's tables recreated empty; archive kept"]
    R3["replay each archived delivery in load order<br/>into the stage"]
    R4["the same narrow staging and model-specific step"]
    R5["query.sh"]
    R1 --> R2 --> R3 --> R4 --> R5
  end

  subgraph TST["make test"]
    direction TB
    T1["tests/run_tests.sh<br/>a throwaway warehouse and archive"]
    T2["init_db.sh, load_feed.sh<br/>D0 to D5, then tests/fixtures/*.sql"]
    T3["36 core assertions, C01 to C14<br/>Q1 to Q9 from tests/answers/*.sql;<br/>rebuild.sh for C11"]
    T4["the model's own assertions, M01 onwards"]
    T5["Summary<br/>RESULT, CORE, MODEL, GAP"]
    T1 --> T2 --> T3 --> T4 --> T5
  end

  subgraph MUT["make mutate"]
    direction TB
    M1["../tests/run_mutations.sh &lt;model&gt;"]
    M2["for each tests/mutations/*.mut:<br/>copy the model to scratch, apply the patch"]
    M3["run tests/run_tests.sh on the copy"]
    M4["KILLED, SURVIVED or known survivor"]
    M1 --> M2 --> M3 --> M4
  end

  D4 -. "the archive rebuild reads" .-> R3
  R4 -. "same code" .-> D6
  M3 -. "the same suite" .-> T1
```

## Who does each step

One row per generic step, one column per model. A dash means the model
has no such step.

| Step | inmon-3nf | data-marts | datavault | focal-point | anchor | hook | unified-star-schema | activity-schema | metrics-mart | one-big-table |
|---|---|---|---|---|---|---|---|---|---|---|
| Shared helpers, sourced by every script | lib.sh | lib.sh | lib.sh | lib.sh | lib.sh | lib.sh | lib.sh | lib.sh | lib.sh | lib.sh |
| Create the archive and the model's tables (`make init`, demo, rebuild) | init_db.sh: 02_archive.sql, 01_stage.sql, 03_edw.sql | init_db.sh: 02_archive.sql, 01_stage.sql, 03_dimensions.sql, 04_facts.sql | init_db.sh: 02_archive.sql, 01_stage.sql, 02_stage2_views.sql, 03_raw_vault.sql, 04_business_vault.sql, 05_info_mart.sql | init_db.sh: 05_archive.sql, 01_metadata.sql, 02_data.sql, 03_seed_metadata.sql, 04_views.sql | init_db.sh: 02_archive.sql, 01_landing.sql, 03_anchor.sql, 04_views.sql | init_db.sh: 02_archive.sql, 01_stage.sql, 03_hook.sql, 04_views.sql | init_db.sh: 02_archive.sql, 01_stage.sql, 03_core.sql, 04_uss.sql | init_db.sh: 02_archive.sql, 01_stage.sql, 03_activity.sql, 04_views.sql | init_db.sh: 02_archive.sql, 01_landing.sql, 03_mart.sql, 04_seed.sql, 05_views.sql | init_db.sh: 02_archive.sql, 01_stage.sql |
| Stage the delivery | load_feed.sh into 01_stage.sql tables | load_feed.sh into 01_stage.sql tables | load_feed.sh into 01_stage.sql tables | load_feed.sh into 01_metadata.sql tables | load_feed.sh into 01_landing.sql tables | load_feed.sh into 01_stage.sql tables | load_feed.sh into 01_stage.sql tables | load_feed.sh into 01_stage.sql tables | load_feed.sh into 01_landing.sql tables | load_feed.sh into 01_stage.sql tables |
| Load control and the load_manifest (`loaded_files`) | load_feed.sh; 02_archive.sql | load_feed.sh; 02_archive.sql | load_feed.sh; 02_archive.sql | load_feed.sh; 05_archive.sql | load_feed.sh; 02_archive.sql | load_feed.sh; 02_archive.sql | load_feed.sh; 02_archive.sql | load_feed.sh; 02_archive.sql | load_feed.sh; 02_archive.sql | load_feed.sh; 02_archive.sql |
| Wide archive, insert-only (`hist_*`) | load_feed.sh; 02_archive.sql | load_feed.sh; 02_archive.sql | load_feed.sh; 02_archive.sql | load_feed.sh; 05_archive.sql | load_feed.sh; 02_archive.sql | load_feed.sh; 02_archive.sql | load_feed.sh; 02_archive.sql | load_feed.sh; 02_archive.sql | load_feed.sh; 02_archive.sql | load_feed.sh; 02_archive.sql |
| Narrow staging: wide rows to key/value rows | — | — | — | stage_narrow.sh | stage_narrow.sh | — | — | — | stage_narrow.sh | — |
| Model-specific step | apply_delivery.sh → load_edw.sh | apply_delivery.sh → load_dims.sh, load_facts.sh | apply_delivery.sh → load_hubs.sh, load_sats.sh, load_links.sh | apply_delivery.sh → load_keys.sh, load_desc.sh, load_rel.sh | apply_delivery.sh → load_anchors.sh, load_attributes.sh, load_ties.sh | apply_delivery.sh → load_frames.sh | apply_delivery.sh → load_core.sh | apply_delivery.sh → load_activities.sh | apply_delivery.sh → route_stage.sh, load_res.sh, load_groups.sh, load_metrics.sh | no apply_delivery.sh: load_feed.sh → refresh_latest.sh, a full refresh over the log |
| Model-only step after the load | — | — | business vault: the 04_business_vault.sql views, and refresh_query_assist.sh rewrites its bv_ query-assist tables | — | — | — | the bridge: refresh_uss.sh (also `make refresh`) | — | aggregates: refresh_aggregates.sh | — |
| Delete rule (a FULL delivery's absences) applied in | load_edw.sh | load_dims.sh | load_sats.sh | load_desc.sh, load_rel.sh | load_attributes.sh | load_frames.sh | load_core.sh | load_activities.sh | route_stage.sh, load_groups.sh | refresh_latest.sh |
| Views (`make demo` and `make rebuild` print them) | query.sh | query.sh | query.sh | query.sh | query.sh | query.sh | query.sh | query.sh | query.sh | query.sh reads 03_log_views.sql (temporary views over the log) |
| Rebuild from the archive | rebuild.sh | rebuild.sh | rebuild.sh | rebuild.sh, stage_narrow.sh | rebuild.sh, stage_narrow.sh | rebuild.sh | rebuild.sh | rebuild.sh | rebuild.sh, stage_narrow.sh | rebuild.sh → refresh_latest.sh |
| Suite (`make test`) | run_tests.sh | run_tests.sh | run_tests.sh, which also runs `make rebuild` | run_tests.sh, which also runs `make rebuild` and archive_status.sh | run_tests.sh, which also runs `make rebuild` | run_tests.sh | run_tests.sh | run_tests.sh | run_tests.sh, which also runs `make rebuild` | run_tests.sh, which reads 03_log_views.sql |
| Mutations (`make mutate`, via ../tests/run_mutations.sh) | 23 in tests/mutations/ | 26 | 25 | 24 | 23 | 26 | 26 | 25 | 41 | 22 |
| Other targets | — | `make archive-status`: archive_status.sh | — | `make archive-status`: archive_status.sh | — | — | `make refresh`: refresh_uss.sh | — | — | — |

Every model also has `make clean` (removes `build/`), `make clean-archive`
(removes `archive/`) and `make help`, which run no script. Every suite
reads its nine answers from `tests/answers/Q1.sql` to `Q9.sql` and its
extra deliveries from `tests/fixtures/`.
