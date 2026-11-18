-- Q5. What does O-100's status read as?  Expected: PENDING (raw 'P')
-- The core keeps 'P'; the materialised orders table holds the decoded label.
SELECT status FROM v_order WHERE order_ref = 'O-100';
