# Repo-level targets. Each warehouse keeps its own Makefile in v3_*/.
.PHONY: help verify

help:
	@echo "make verify   clean, demo and test every v3_* warehouse; write VERIFY.md"

verify:
	@./tools/verify.sh
