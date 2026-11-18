-- Q5. What does O-100's status read as?  Expected: PENDING (raw 'P')
-- res_order keeps 'P'; the order_status code table decodes it on read.
SELECT status FROM v_order WHERE order_ref = 'O-100';
