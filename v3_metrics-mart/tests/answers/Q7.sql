-- Q7. Who placed O-101, as at purchase?  Expected: Bob Jones
-- CANNOT: current-state model: the order's parent is updated in place on a re-point; needs a history table for the parent link
-- Needs the archive attached as `arch`. The mart keeps current state: an
-- order's parent resource is updated in place on a re-point, so the
-- purchase-time owner survives only in the archive (answering it from the
-- mart would need a history table for the parent link). The order's
-- first archived row, and that customer's latest archived row as of the
-- same delivery.
WITH o AS (SELECT customer_ref, load_seq FROM arch.hist_order
           WHERE order_ref = 'O-101' ORDER BY load_seq, seq_nbr LIMIT 1)
SELECT c.full_name FROM arch.hist_customer c, o
WHERE c.customer_id = o.customer_ref AND c.op = 'UPSERT' AND c.load_seq <= o.load_seq
ORDER BY c.load_seq DESC, c.seq_nbr DESC LIMIT 1;
