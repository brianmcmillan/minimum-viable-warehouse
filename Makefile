# Repo-level targets. Each warehouse keeps its own Makefile in v3_*/.
.PHONY: help verify core-check mutate compare

help:
	@echo "make verify       clean, demo and test every v3_* warehouse; write VERIFY.md"
	@echo "make core-check   every suite emits the core assertions of tests/core_spec.tsv, once each, in order"
	@echo "make compare      ask all ten models the nine shared questions; write ANSWERS.md and the README end state"
	@echo "make mutate       run every v3_*/tests/mutations/ against its suite; write MUTATIONS.md"

verify:
	@bash tools/verify.sh

core-check:
	@bash tests/check_core.sh

mutate:
	@bash tests/run_mutations.sh --report MUTATIONS.md

compare:
	@bash compare/run.sh
