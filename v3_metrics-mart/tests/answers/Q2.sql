-- Q2. Which customers are deleted?  Expected after D5: C002,C003
-- One RES table for every type; res_status 0 is deleted.
SELECT group_concat(res_code, ',') FROM (
  SELECT res_code FROM v_res WHERE res_type = 'CUSTOMER' AND status = 'DELETED' ORDER BY res_code);
