-- Q5. What does O-100's status read as?  Expected: PENDING (raw 'P')
-- The table keeps 'P'; the CASE in v_order translates it for this consumer.
SELECT status FROM v_order WHERE order_ref = 'O-100';
