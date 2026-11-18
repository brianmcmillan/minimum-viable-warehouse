-- Q4. What has SKU-1's price been, oldest first?  Expected after D2: 9.99>8.99
SELECT group_concat(price, '>') FROM (
  SELECT price FROM core_product WHERE sku = 'SKU-1' AND change_type <> 'DELETE' ORDER BY load_ts);
