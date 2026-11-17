# Mutations for C3 to implement

C2d adds no mutation harness. Each mutation below is a code change that
some assertion in `tests/run_tests.sh` must catch. C3 should apply each
one in a scratch copy, run the suite, and require at least one FAIL.

1. **Skip the CPIT refresh.** Make `scripts/refresh_query_assist.sh`
   leave the three `bv_*_cpit` tables untouched. Expected catch: CPIT
   pointers no longer equal the newest satellite rows after a delivery.
2. **Skip the bridge refresh.** Remove the `bv_order_bridge` rewrite.
   Expected catch: after the re-point fixture the bridge still has
   O-101's line under C002, and the null-customer fixture's lines are
   missing.
3. **Decode from the first reference row instead of the latest.** In
   `bv_order_status_bsat`, order `ref_order_status` by `ldts ASC`.
   Expected catch: inserting a newer `P` row does not relabel history.
4. **Drop the reserved-key filter from `dim_customer`.** Expected catch:
   "no reserved key in any mart view". It currently survives (checked by
   hand on 17 November 2026): the CPIT holds real keys only, and the
   `'-1'` key has no `'I'` status row, so the filter is defence in depth.
   C3 should decide whether to accept a surviving mutant here or make
   the filter load-bearing (for example, by building the dimension from
   the hub rather than the CPIT).
5. **Link a null `customer_ref` to `'-2'` instead of `'-1'`.** Change
   the COALESCE in `v_stg_order_l2`. Expected catch: the null-customer
   fixture's O-102 is linked to `'-2'`, not `'-1'`.
