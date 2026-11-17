-- Q7. Who placed O-101, as at purchase?  Expected: Bob Jones
-- Satellite as-of: the order's first effectivity pairing, and that
-- customer's satellite row as it stood when the pairing opened.
SELECT s.full_name
FROM v_order_customer_eff_history e
JOIN rv_customer_hsat s ON s.customer_bk = e.customer_bk
WHERE e.order_bk = 'O-101'
  AND e.start_date = (SELECT MIN(start_date) FROM v_order_customer_eff_history WHERE order_bk = 'O-101')
  AND s.ldts = (SELECT MAX(ldts) FROM rv_customer_hsat x
                WHERE x.customer_bk = e.customer_bk AND x.ldts <= e.start_date);
