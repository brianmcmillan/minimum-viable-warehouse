-- Q7. Who placed O-101, as at purchase?  Expected: Bob Jones
-- SCD2 on the pairing: O-101's first dim_order_owner version (the owner
-- when the star first recorded the order), named by that customer's
-- dim_customer version current at the same moment. A re-point closes
-- that version and leaves it as it was.
SELECT c.customer_name
FROM dim_order_owner o
JOIN dim_customer c ON c.customer_ref = o.customer_ref
                   AND c.row_eff_ts <= o.row_eff_ts AND o.row_eff_ts < c.row_exp_ts
WHERE o.order_ref = 'O-101'
  AND o.row_eff_ts = (SELECT MIN(row_eff_ts) FROM dim_order_owner WHERE order_ref = 'O-101');
