# Repo-level targets. Each warehouse keeps its own Makefile in v3_*/.
.PHONY: help verify core-check

help:
	@echo "make verify       clean, demo and test every v3_* warehouse; write VERIFY.md"
	@echo "make core-check   every suite emits the core assertions of tests/core_spec.tsv, once each, in order"

verify:
	@bash tools/verify.sh

core-check:
	@bash tests/check_core.sh
