# Kimball star schema on SQLite, with a Persistent Staging Area.
# Third leg of the model-comparison set: same deliveries as
# ../v3_focal-point (Focal) and ../v3_datavault (DV 2.0).
SQLITE ?= sqlite3
DB     ?= build/datamart.db
PSA_DB ?= psa/psa_datamart.db
export SQLITE
export DB
export PSA_DB

.PHONY: help init demo rebuild test psa-status clean clean-psa
help:
	@echo "  make demo        - fresh PSA + init + the full delivery sequence + star"
	@echo "  make rebuild     - regenerate the star by replaying the PSA"
	@echo "  make psa-status  - report on the persistent staging area (read-only)"
	@echo "  make test        - run the Kimball test suite"
	@echo "  make clean       - delete build/  (the PSA SURVIVES)"
	@echo "  make clean-psa   - delete psa/ -- destroys the raw history, and with it"
	@echo "                     any ability to rebuild. Deliberately not part of clean."
init:
	@./scripts/init_db.sh

# Deliveries are skipped once COMPLETE, so a repeatable demo needs a
# fresh PSA. This is the only target that discards it implicitly.
demo:
	@rm -rf "$(dir $(PSA_DB))"
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

psa-status:
	@./scripts/psa_status.sh

test:
	@./tests/run_tests.sh

clean:
	@rm -rf build && echo "removed build/ (psa/ untouched -- run 'make rebuild')"

clean-psa:
	@rm -rf "$(dir $(PSA_DB))" && echo "removed $(dir $(PSA_DB)) -- the raw history is gone"
