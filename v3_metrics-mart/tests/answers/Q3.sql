-- Q3. What has C001's email been, oldest first?  Expected: alice@example.com>alice@newmail.com
-- CANNOT: current-state model: the email is updated in place; history would need a history table
-- Needs the archive attached as `arch`. The mart keeps current state and
-- updates the email in place; the history is answered from the raw
-- archive, the final answer: keep each value that differs from the one
-- before it (LAG over the log).
SELECT group_concat(email_addr, '>') FROM (
  SELECT email_addr, LAG(email_addr) OVER (ORDER BY load_seq, extract_dt, seq_nbr) AS prev
  FROM arch.hist_customer WHERE customer_id = 'C001' AND op = 'UPSERT')
WHERE prev IS NULL OR email_addr IS NOT prev;
