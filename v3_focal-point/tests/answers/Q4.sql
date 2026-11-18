-- Q4. What has SKU-1's price been, oldest first?  Expected after D2: 9.99>8.99
-- Every open version of the PRODUCT_PRICE context (type_key 21).
SELECT group_concat(d.val_num, '>') FROM (
  SELECT val_num FROM product_desc d JOIN product_idfr i ON i.product_key = d.product_key
  WHERE i.product_idfr = 'SKU-1' AND d.type_key = 21 AND d.row_st = 'Y'
  ORDER BY d.eff_tmstp, d.ver_tmstp) d;
