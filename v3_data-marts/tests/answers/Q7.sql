-- Q7. Who placed O-101, as at purchase?  Expected: Bob Jones
-- RAW: the re-point restates the fact in place and re-freezes its customer key; needs SCD2 history on the order-customer pairing
-- Needs the archive attached as `arch`. The star keeps current state for
-- this question: a re-point restates the fact in place and re-freezes its
-- customer key to the new owner's current version, so the purchase-time
-- owner survives only in the archive (answering it from the star would
-- need SCD2 history on the order-customer pairing). The order's first
-- archived row, and that customer's latest archived row as of the same
-- delivery.
WITH o AS (SELECT customer_ref, load_seq FROM arch.hist_order
           WHERE order_ref = 'O-101' ORDER BY load_seq, seq_nbr LIMIT 1)
SELECT c.full_name FROM arch.hist_customer c, o
WHERE c.customer_id = o.customer_ref AND c.op = 'UPSERT' AND c.load_seq <= o.load_seq
ORDER BY c.load_seq DESC, c.seq_nbr DESC LIMIT 1;
