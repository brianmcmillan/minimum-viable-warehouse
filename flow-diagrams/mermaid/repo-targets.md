# Repo targets: the root Makefile and CI, traced

Level 2, traced. Every root `make` target and the CI job, down to the
`make` calls each one makes into the `v3_*` directories and the files it
writes. Found by `tools/trace_flows.sh`, which prints the same graph as
indented trees; `make trace-check` fails if a script a target runs is
missing here or from [model-pipeline.md](model-pipeline.md). See the
[README](../README.md) for how to read it.

```mermaid
flowchart LR
  CI["CI job all<br/>.github/workflows/ci.yml<br/>JOBS=4 make all, on macOS and Ubuntu"]
  ART[/"artifacts results-&lt;os&gt;<br/>VERIFY.md, MUTATIONS.md,<br/>ANSWERS.md, MANIFEST.md"/]
  ALL{"make all<br/>each step runs even if one fails"}

  VER["make verify<br/>tools/verify.sh"]
  CC["make core-check<br/>tests/check_core.sh"]
  MUT["make mutate<br/>tests/run_mutations.sh --report MUTATIONS.md"]
  CMP["make compare<br/>compare/run.sh"]
  MAN["make manifest<br/>tools/manifest.sh"]
  TRC["make trace-check<br/>tools/trace_flows.sh --check"]
  CHK["make check-results<br/>tools/check_results.sh"]
  TS["tools/tree_state.sh<br/>(sourced: did the run change the tree?)"]

  MV["in each v3_*/ in place:<br/>make clean, make demo, make test"]
  RT["in each v3_*/:<br/>./tests/run_tests.sh"]
  MM["per mutation, in a scratch copy of v3_*/:<br/>apply tests/mutations/*.mut,<br/>then ./tests/run_tests.sh"]
  MCP["per model, in a scratch copy of v3_*/:<br/>make demo, then ./scripts/load_feed.sh<br/>tests/fixtures/d*_repoint.sql D6,<br/>then tests/answers/Q1..Q9.sql;<br/>Q9 after compare/rules/&lt;model&gt;.sh"]

  W1[/"VERIFY.md, verify-logs/,<br/>v3_*/build/, v3_*/archive/"/]
  W2[/"MUTATIONS.md"/]
  W3[/"ANSWERS.md and the README.md<br/>end-state block"/]
  W4[/"MANIFEST.md"/]
  R1[/"reads compare/models.tsv,<br/>questions.tsv, decisions.tsv"/]
  R2[/"reads flow-diagrams/mermaid/<br/>repo-targets.md, model-pipeline.md"/]
  R3[/"reads the committed copies<br/>(git HEAD) of the four reports"/]

  CI --> ALL
  CI -.-> ART
  ALL --> VER & MUT & CMP & MAN & TRC & CHK
  VER --> MV
  VER --> W1
  CC --> RT
  MUT --> MM
  MUT --> W2
  CMP --> MCP
  CMP --> W3
  CMP -.-> R1
  MAN --> W4
  TRC -.-> R2
  CHK -.-> R3
  VER & MUT & CMP -. "source" .-> TS
```

Each box inside a `v3_*` directory is drawn once for all ten: the
model's own tree is in [model-pipeline.md](model-pipeline.md).
`make core-check` is run by hand; `make all` does not run it. No root
target runs `flow-diagrams/render.sh` or `er-diagrams/generate.py`.
