-- Q7. Who placed O-101, as at purchase?  Expected: Bob Jones
-- Bi-temporal: the order's first PLACED_BY pairing, and that customer's
-- CUSTOMER_NAME version in effect when the pairing was recorded.
WITH p AS (SELECT x.customer_key, x.eff_tmstp FROM order_customer_x x
           JOIN order_idfr o ON o.order_key = x.order_key
           WHERE o.order_idfr = 'O-101' AND x.type_key = 90 AND x.row_st = 'Y'
           ORDER BY x.eff_tmstp, x.ver_tmstp LIMIT 1)
SELECT d.val_str FROM customer_desc d, p
WHERE d.customer_key = p.customer_key AND d.type_key = 10 AND d.row_st = 'Y'
  AND d.eff_tmstp <= p.eff_tmstp
ORDER BY d.eff_tmstp DESC, d.ver_tmstp DESC LIMIT 1;
