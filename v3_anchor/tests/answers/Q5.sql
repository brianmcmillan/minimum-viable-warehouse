-- Q5. What does O-100's status read as?  Expected: PENDING (raw 'P')
-- The loader resolves 'P' to a knot; the label is read from the knot.
SELECT status FROM v_order WHERE order_ref = 'O-100';
