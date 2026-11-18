# Mutations for C3 to implement

C2e adds no mutation harness. Each mutation below is a code change that
some assertion in `tests/run_tests.sh` (which now holds the former
`tests/test_archive.sh` checks as model sections) must
catch. C3 should apply each one in a scratch copy, run the suite, and
require at least one FAIL.

1. **Drop the existence filter from `v_customer`.** Remove the join on
   `CUSTOMER_EXISTENCE` (type_key 19) = `'ACTIVE'` in `schema/04_views.sql`.
   Expected catch: "tombstone: C002 gone from v_customer", the end-state
   string after D5, and "replay: C002 still deleted by tombstone".
2. **Skip the DELETED write on FULL absence.** In `scripts/load_desc.sh`,
   make the existence loop's FULL-absence branch select nothing.
   Expected catch: SKU-3 and C003 stay ACTIVE in `v_product_status` /
   `v_customer_status` and reappear in `v_product` / `v_customer`.
3. **Skip the ACTIVE write on a restore.** In the existence loop, write
   ACTIVE only for keys with no existence row at all (`t.ek IS NULL`),
   not for keys whose current existence is DELETED. Expected catch: the
   d8_restore.sql assertions -- C002's existence stays DELETED and it is
   missing from `v_customer` although its attributes reopened.
