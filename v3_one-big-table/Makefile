# One Big Table / no-model on SQLite. The null hypothesis of the
# model-comparison set: same wide deliveries as ../v3_datavault.
SQLITE     ?= sqlite3
DB         ?= build/obt.db
ARCHIVE_DB ?= archive/obt_archive.db
export SQLITE
export DB
export ARCHIVE_DB

.PHONY: help init demo rebuild test clean clean-archive
help:
	@echo "  make demo          - fresh archive + the full delivery sequence + tables"
	@echo "  make rebuild       - init + ONE full refresh (no replay loop needed)"
	@echo "  make test          - run the OBT test suite"
	@echo "  make clean         - delete build/  (the ARCHIVE -- the real warehouse -- SURVIVES)"
	@echo "  make clean-archive - delete archive/ -- destroys everything"
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
	@rm -rf "$(dir $(ARCHIVE_DB))" && echo "removed $(dir $(ARCHIVE_DB)) -- the warehouse is gone"
