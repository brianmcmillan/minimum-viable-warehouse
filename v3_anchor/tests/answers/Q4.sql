-- Q4. What has SKU-1's price been, oldest first?  Expected after D2: 9.99>8.99
SELECT group_concat(p.Product_Price, '>') FROM (
  SELECT p.Product_Price FROM PR_PRC_Product_Price p
  JOIN PR_REF_Product_Reference r ON r.PR_ID = p.PR_ID
  WHERE r.Product_Reference = 'SKU-1' ORDER BY p.ChangedAt) p;
