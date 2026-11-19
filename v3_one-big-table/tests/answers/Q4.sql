-- Q4. What has SKU-1's price been, oldest first?  Expected after D2: 9.99>8.99
-- v_product_version: SKU-1's versions, each a change from the one before.
.read v3_one-big-table/schema/03_log_views.sql
SELECT group_concat(price, '>') FROM (
  SELECT price FROM v_product_version WHERE sku = 'SKU-1' ORDER BY valid_from);
