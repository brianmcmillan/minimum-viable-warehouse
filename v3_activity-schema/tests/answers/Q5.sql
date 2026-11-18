-- Q5. What does O-100's status read as?  Expected: PENDING (raw 'P')
-- The stream keeps 'P'; v_order joins the reference table on read.
SELECT status FROM v_order WHERE order_ref = 'O-100';
