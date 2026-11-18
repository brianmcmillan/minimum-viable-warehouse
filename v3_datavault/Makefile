# Data Vault 2.0 on SQLite (natural-key variant). Requires bash, make, sqlite3.
# Vault leg of the model-comparison set: same wide deliveries as
# ../v3_data-marts, ../v3_inmon-3nf, ../v3_hook, ../v3_unified-star-schema
# and ../v3_one-big-table; same logical scenario and tests as ../v3_focal-point.
SQLITE     ?= sqlite3
DB         ?= build/datavault.db
ARCHIVE_DB ?= archive/datavault_archive.db
export SQLITE
export DB
export ARCHIVE_DB

.PHONY: help init demo rebuild test mutate clean clean-archive
help:
	@echo "  make demo          - fresh archive + init + the full delivery sequence + info mart"
	@echo "  make rebuild       - regenerate the vault by replaying the raw layer"
	@echo "  make test          - run the Data Vault test suite"
	@echo "  make mutate        - break the code on purpose (tests/mutations/), check the suite catches it"
	@echo "  make clean         - delete build/  (the ARCHIVE SURVIVES)"
	@echo "  make clean-archive - delete archive/ -- destroys the raw layer"
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

mutate:
	@../tests/run_mutations.sh $(notdir $(CURDIR))

clean:
	@rm -rf build && echo "removed build/ (archive/ untouched -- run 'make rebuild')"

clean-archive:
	@rm -rf "$(dir $(ARCHIVE_DB))" && echo "removed $(dir $(ARCHIVE_DB)) -- the raw layer is gone"
