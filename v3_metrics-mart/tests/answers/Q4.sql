-- Q4. What has SKU-1's price been, oldest first?  Expected after D2: 9.99>8.99
-- Prices are metric samples, so their history is kept.
SELECT group_concat(printf('%.2f', value), '>') FROM (
  SELECT value FROM v_metric_sample WHERE res_code = 'SKU-1' AND metric_code = 'price' ORDER BY sample_utc_ts);
