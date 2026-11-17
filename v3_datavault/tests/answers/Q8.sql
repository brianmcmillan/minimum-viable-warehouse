-- Q8. Who owns O-101 now?  Expected after the re-point: Alice Smith (and nobody else)
-- Every current effectivity pairing for the driving key, by name.
SELECT group_concat(d.customer_name, ',')
FROM v_order_customer_current c JOIN dim_customer d ON d.customer_ref = c.customer_bk
WHERE c.order_bk = 'O-101';
