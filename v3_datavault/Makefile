# Data Vault 2.0 on SQLite (natural-key variant). Requires bash, make, sqlite3.
# Vault leg of the model-comparison set: same wide deliveries as
# ../v3_data-marts, ../v3_inmon-3nf, ../v3_hook, ../v3_unified-star-schema
# and ../v3_one-big-table; same logical scenario and tests as ../v3_focal-point.
SQLITE ?= sqlite3
DB     ?= build/datavault.db
export SQLITE
export DB

.PHONY: help init demo test clean
help:
	@echo "  make demo   - init + run the full delivery sequence + info mart"
	@echo "  make test   - run the Data Vault test suite"
	@echo "  make clean  - delete build/"
init:
	@./scripts/init_db.sh
demo: init
	@BATCH_TS='2026-02-05 08:00:00' ./scripts/load_feed.sh source/d0_baseline.sql        B0
	@BATCH_TS='2026-03-02 08:00:00' ./scripts/load_feed.sh source/d1_cust_win_day60.sql   D1
	@BATCH_TS='2026-03-02 09:00:00' ./scripts/load_feed.sh source/d2_prod_full_v2.sql     D2
	@BATCH_TS='2026-03-16 08:00:00' ./scripts/load_feed.sh source/d3_cust_tombstone.sql   D3
	@BATCH_TS='2026-04-02 08:00:00' ./scripts/load_feed.sh source/d4_cust_recency.sql     D4
	@BATCH_TS='2026-12-31 08:00:00' ./scripts/load_feed.sh source/d5_cust_yearly_full.sql D5
	@./scripts/query.sh
test:
	@./tests/run_tests.sh
clean:
	@rm -rf build && echo "removed build/"
