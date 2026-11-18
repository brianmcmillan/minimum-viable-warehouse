-- Q4. What has SKU-1's price been, oldest first?  Expected after D2: 9.99>8.99
-- Needs the archive attached as `arch`. The same LAG diff over the log.
SELECT group_concat(price, '>') FROM (
  SELECT price, LAG(price) OVER (ORDER BY load_seq, extract_dt, seq_nbr) AS prev
  FROM arch.hist_product WHERE sku = 'SKU-1' AND op = 'UPSERT')
WHERE prev IS NULL OR price IS NOT prev;
