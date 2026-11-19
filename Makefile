# Repo-level targets. Each warehouse keeps its own Makefile in v3_*/.
.PHONY: help all verify core-check mutate compare check-results

help:
	@echo "make all          verify, mutate and compare, then fail if any result differs from the committed copies"
	@echo "make verify       clean, demo and test every v3_* warehouse; write VERIFY.md"
	@echo "make core-check   every suite emits the core assertions of tests/core_spec.tsv, once each, in order"
	@echo "make compare      ask all ten models the nine shared questions; write ANSWERS.md and the README end state"
	@echo "make mutate       run every v3_*/tests/mutations/ against its suite; write MUTATIONS.md"

# All three run even if one fails, so every report is written; then the
# results are compared with the committed copies (tools/check_results.sh).
all:
	@rc=0; \
	$(MAKE) --no-print-directory verify  || rc=1; \
	$(MAKE) --no-print-directory mutate  || rc=1; \
	$(MAKE) --no-print-directory compare || rc=1; \
	bash tools/check_results.sh || rc=1; \
	exit $$rc

check-results:
	@bash tools/check_results.sh

verify:
	@bash tools/verify.sh

core-check:
	@bash tests/check_core.sh

mutate:
	@bash tests/run_mutations.sh --report MUTATIONS.md

compare:
	@bash compare/run.sh
