-- Q4. What has SKU-1's price been, oldest first?  Expected after D2: 9.99>8.99
SELECT group_concat(json_extract(feature_json, '$.price'), '>') FROM (
  SELECT feature_json FROM product_stream
  WHERE customer = 'SKU-1' AND activity IN ('added', 'updated_price', 'restored')
    AND json_extract(feature_json, '$.price') IS NOT NULL
  ORDER BY ts, _seq);
