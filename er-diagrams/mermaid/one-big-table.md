# One Big Table — ER diagrams

Generated from [`v3_one-big-table/build/obt.db`](../../v3_one-big-table/build/obt.db) and `archive/obt_archive.db` by `er-diagrams/generate.py`. Design notes: [`v3_one-big-table/OBT.md`](../../v3_one-big-table/OBT.md).

> `PK` is a primary-key column and `FK` a declared foreign key. A solid
> line is a declared foreign key; a dashed line is a join the model
> intends but does not declare. The crow's foot is the "many" side.

This model declares none of its relationships as foreign keys, so 3 dashed lines were added by hand in the generator.

## 1 · Core model

Full-refresh tables recomputed from the log. `obt_order_wide` is the one big table; it repeats the others' columns and joins to nothing.

```mermaid
erDiagram
    obt_customer {
        TEXT customer_ref PK
        TEXT full_name
        TEXT email
        TEXT signup_date
    }
    obt_order_lines {
        TEXT order_ref PK
        TEXT sku PK
    }
    obt_order_wide {
        TEXT order_ref PK
        TEXT placed_at
        TEXT status
        REAL amount
        TEXT currency
        TEXT customer_ref
        TEXT customer_name
        TEXT email
        TEXT sku PK
        TEXT product_name
        REAL price
    }
    obt_orders {
        TEXT order_ref PK
        TEXT customer_ref
        TEXT status
        REAL amount
        TEXT currency
        TEXT placed_at
    }
    obt_product {
        TEXT sku PK
        TEXT product_name
        REAL price
        TEXT currency
    }
    obt_customer ||..o{ obt_orders : "customer_ref"
    obt_orders ||..o{ obt_order_lines : "order_ref"
    obt_product ||..o{ obt_order_lines : "sku"
```

## 2 · Staging

Where a delivery lands before it is applied. Staging tables hold source names, so they have no relationships.

```mermaid
erDiagram
    stg_customer_l1 {
        TEXT customer_id
        TEXT full_name
        TEXT email_addr
        TEXT signup_date
        TEXT extract_dt
        TEXT op
        TEXT load_mode
    }
    stg_order_l1 {
        TEXT order_ref
        TEXT customer_ref
        TEXT status
        REAL amount
        TEXT currency
        TEXT placed_at
        TEXT extract_dt
        TEXT op
        TEXT load_mode
    }
    stg_order_line_l1 {
        TEXT order_ref
        TEXT sku
        TEXT extract_dt
        TEXT op
        TEXT load_mode
    }
    stg_product_l1 {
        TEXT sku
        TEXT prod_name
        REAL price
        TEXT currency
        TEXT extract_dt
        TEXT op
        TEXT load_mode
    }
```

## 3 · Raw layer (archive)

The durable raw layer, in its own database file. Every delivery is captured here verbatim before it is applied, and the tables are append-only.

```mermaid
erDiagram
    hist_customer {
        TEXT file_id PK, FK
        INTEGER load_seq
        TEXT batch_ts
        INTEGER seq_nbr PK
        TEXT customer_id
        TEXT full_name
        TEXT email_addr
        TEXT signup_date
        TEXT extract_dt
        TEXT op
        TEXT load_mode
        TEXT archived_at
    }
    hist_order {
        TEXT file_id PK, FK
        INTEGER load_seq
        TEXT batch_ts
        INTEGER seq_nbr PK
        TEXT order_ref
        TEXT customer_ref
        TEXT status
        REAL amount
        TEXT currency
        TEXT placed_at
        TEXT extract_dt
        TEXT op
        TEXT load_mode
        TEXT archived_at
    }
    hist_order_line {
        TEXT file_id PK, FK
        INTEGER load_seq
        TEXT batch_ts
        INTEGER seq_nbr PK
        TEXT order_ref
        TEXT sku
        TEXT extract_dt
        TEXT op
        TEXT load_mode
        TEXT archived_at
    }
    hist_product {
        TEXT file_id PK, FK
        INTEGER load_seq
        TEXT batch_ts
        INTEGER seq_nbr PK
        TEXT sku
        TEXT prod_name
        REAL price
        TEXT currency
        TEXT extract_dt
        TEXT op
        TEXT load_mode
        TEXT archived_at
    }
    loaded_files {
        TEXT file_id PK
        INTEGER load_seq
        TEXT batch_ts
        TEXT status
        TEXT loaded_at
        INTEGER row_count
    }
    loaded_files ||--o{ hist_customer : "file_id"
    loaded_files ||--o{ hist_order : "file_id"
    loaded_files ||--o{ hist_order_line : "file_id"
    loaded_files ||--o{ hist_product : "file_id"
```
