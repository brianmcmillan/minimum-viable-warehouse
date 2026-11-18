-- Q7. Who placed O-101, as at purchase?  Expected: Bob Jones
-- RAW: the latest tables keep the current owner only; the purchase-time owner is in the log alone
-- Needs the archive attached as `arch`. The order's first logged row, and
-- that customer's latest logged row as of the same delivery.
WITH o AS (SELECT customer_ref, load_seq FROM arch.hist_order
           WHERE order_ref = 'O-101' ORDER BY load_seq, seq_nbr LIMIT 1)
SELECT c.full_name FROM arch.hist_customer c, o
WHERE c.customer_id = o.customer_ref AND c.op = 'UPSERT' AND c.load_seq <= o.load_seq
ORDER BY c.load_seq DESC, c.seq_nbr DESC LIMIT 1;
