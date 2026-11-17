-- Q4. What has SKU-1's price been, oldest first?  Expected after D2: 9.99>8.99
SELECT group_concat(price, '>') FROM (
  SELECT price FROM rv_product_hsat WHERE product_bk = 'SKU-1' ORDER BY ldts);
