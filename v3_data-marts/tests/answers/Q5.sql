-- Q5. What does O-100's status read as?  Expected: PENDING (raw 'P')
-- The fact carries a status key; the decode dimension holds the label.
SELECT status FROM mart_orders WHERE order_ref = 'O-100';
