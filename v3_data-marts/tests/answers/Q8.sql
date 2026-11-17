-- Q8. Who owns O-101 now?  Expected after the re-point: Alice Smith (and nobody else)
SELECT group_concat(placed_by_current, ',') FROM mart_orders WHERE order_ref = 'O-101';
