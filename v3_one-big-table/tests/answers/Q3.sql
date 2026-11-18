-- Q3. What has C001's email been, oldest first?  Expected: alice@example.com>alice@newmail.com
-- RAW: the latest tables keep current values only; email history is in the log alone
-- Needs the archive attached as `arch`. History is a query over the log:
-- keep each value that differs from the one before it (LAG).
SELECT group_concat(email_addr, '>') FROM (
  SELECT email_addr, LAG(email_addr) OVER (ORDER BY load_seq, extract_dt, seq_nbr) AS prev
  FROM arch.hist_customer WHERE customer_id = 'C001' AND op = 'UPSERT')
WHERE prev IS NULL OR email_addr IS NOT prev;
