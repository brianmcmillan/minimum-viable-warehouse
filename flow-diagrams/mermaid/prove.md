# Prove: how the repo checks its own claims

Level 1, conceptual. What each suite asserts, the three repo-wide runs
built on the suites, the manifest of every file, the reports they write, and how `make all` and CI
turn those reports into a pass or a fail. See the
[README](../README.md) for how to read it.

```mermaid
flowchart TD
  subgraph SU["Each model's suite: a throwaway warehouse and archive"]
    CO["36 core assertions, C01 to C14<br/>the same ids and labels in all ten:<br/>deliveries, load control, idempotence, append-only archive,<br/>rebuild, rule change, re-point, end state"]
    MO["The model's own assertions<br/>M01 onwards"]
    RS["Summary<br/>passed, failed, core, model, known gaps"]
  end
  CC["make core-check<br/>every suite emits each core id once, in order<br/>(run by hand; not part of make all)"]
  VE["make verify<br/>clean, demo and test every model;<br/>check the counts the README publishes"]
  MU["make mutate<br/>in a copy, break the code one way at a time<br/>and run the suite against each break"]
  CP["make compare<br/>in a copy: demo, the re-point, then Q1 to Q9;<br/>Q9 changes a rule with no reload"]
  VR[/"VERIFY.md<br/>counts per suite"/]
  MR[/"MUTATIONS.md<br/>KILLED or SURVIVED per mutation"/]
  AR[/"ANSWERS.md<br/>and the README end-state block"/]
  MA["make manifest<br/>list every file in the repo"]
  MN[/"MANIFEST.md<br/>the file tree"/]
  AL{"make all<br/>runs all four, then compares their results<br/>with the committed copies"}
  CI["CI on every push and pull request<br/>make all on macOS and on Ubuntu;<br/>the four reports kept as artifacts"]

  CO --> MO --> RS
  CC -. "reads the core ids" .-> SU
  VE -- "runs" --> SU
  MU -- "runs, once per mutation" --> SU
  CP -. "asks the same Q1 to Q9 queries" .-> CO
  VE --> VR
  MU --> MR
  CP --> AR
  MA --> MN
  AL --> VE & MU & CP & MA
  VR & MR & AR & MN -- "results, never run times or versions" --> AL
  CI --> AL
```
