-- Q5. What does O-100's status read as?  Expected: PENDING (raw 'P')
-- The vault keeps 'P'; the computed satellite decodes it on read.
SELECT status FROM fact_order WHERE order_ref = 'O-100';
