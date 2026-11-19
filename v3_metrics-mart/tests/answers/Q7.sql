-- Q7. Who placed O-101, as at purchase?  Expected: Bob Jones
-- The parent of O-101's first version in RES_HIST, named by that
-- customer's version valid when the order was first recorded. A re-point
-- opens a new order version and leaves the first one as it was.
SELECT placed_by_at_purchase FROM v_order_at_purchase WHERE order_ref = 'O-101';
