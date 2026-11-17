-- Q8. Who owns O-101 now?  Expected after the re-point: Alice Smith (and nobody else)
SELECT group_concat(placed_by, ',') FROM v_order WHERE order_ref = 'O-101';
