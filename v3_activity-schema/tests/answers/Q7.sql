-- Q7. Who placed O-101, as at purchase?  Expected: Bob Jones
-- LAST BEFORE on event time: the customer's profile as it stood when the
-- order was placed.
SELECT placed_by_at_purchase FROM v_order_at_purchase WHERE order_ref = 'O-101';
