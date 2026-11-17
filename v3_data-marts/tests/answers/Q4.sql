-- Q4. What has SKU-1's price been, oldest first?  Expected after D2: 9.99>8.99
SELECT group_concat(price, '>') FROM (
  SELECT price FROM dim_product WHERE sku = 'SKU-1' AND is_deleted = 0 ORDER BY row_eff_ts);
