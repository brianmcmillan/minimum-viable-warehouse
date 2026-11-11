# Anchor Modeling (6NF) on SQLite. 6NF leg of the model-comparison set:
# same narrow deliveries as ../v3_focal-point (Focal Point).
SQLITE     ?= sqlite3
DB         ?= build/anchor.db
ARCHIVE_DB ?= archive/anchor_archive.db
export SQLITE
export DB
export ARCHIVE_DB

.PHONY: help init demo rebuild test clean clean-archive
help:
	@echo "  make demo          - fresh archive + init + the full delivery sequence + views"
	@echo "  make rebuild       - regenerate the constellation by replaying the raw layer"
	@echo "  make test          - run the Anchor test suite"
	@echo "  make clean         - delete build/  (the ARCHIVE SURVIVES)"
	@echo "  make clean-archive - delete archive/ -- destroys the raw layer, and with it"
	@echo "                       any ability to rebuild. Deliberately not part of clean."
init:
	@./scripts/init_db.sh

demo:
	@rm -rf "$(dir $(ARCHIVE_DB))"
	@./scripts/init_db.sh
	@BATCH_TS='2026-02-05 08:00:00' ./scripts/load_feed.sh source/d0_baseline.sql        B0
	@BATCH_TS='2026-03-02 08:00:00' ./scripts/load_feed.sh source/d1_cust_win_day60.sql   D1
	@BATCH_TS='2026-03-02 09:00:00' ./scripts/load_feed.sh source/d2_prod_full_v2.sql     D2
	@BATCH_TS='2026-03-16 08:00:00' ./scripts/load_feed.sh source/d3_cust_tombstone.sql   D3
	@BATCH_TS='2026-04-02 08:00:00' ./scripts/load_feed.sh source/d4_cust_recency.sql     D4
	@BATCH_TS='2026-12-31 08:00:00' ./scripts/load_feed.sh source/d5_cust_yearly_full.sql D5
	@./scripts/query.sh

rebuild:
	@./scripts/rebuild.sh
	@./scripts/query.sh

test:
	@./tests/run_tests.sh

clean:
	@rm -rf build && echo "removed build/ (archive/ untouched -- run 'make rebuild')"

clean-archive:
	@rm -rf "$(dir $(ARCHIVE_DB))" && echo "removed $(dir $(ARCHIVE_DB)) -- the raw layer is gone"
