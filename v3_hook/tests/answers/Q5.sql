-- Q5. What does O-100's status read as?  Expected: PENDING (raw 'P')
-- The frame keeps 'P'; v_order decodes it through the reference table on read.
SELECT status FROM v_order WHERE order_ref = 'O-100';
