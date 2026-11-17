-- Q7. Who placed O-101, as at purchase?  Expected: Bob Jones
-- The fact's FROZEN surrogate key points at the customer version current
-- when the order was loaded: an equi-join, no date range.
SELECT placed_by_at_purchase FROM mart_orders WHERE order_ref = 'O-101';
