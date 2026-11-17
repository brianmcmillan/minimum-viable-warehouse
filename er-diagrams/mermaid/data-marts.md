# Kimball star — ER diagrams

Generated from [`v3_data-marts/build/datamart.db`](../../v3_data-marts/build/datamart.db) and `archive/datamart_archive.db` by `er-diagrams/generate.py`. Design notes: [`v3_data-marts/DATAMART.md`](../../v3_data-marts/DATAMART.md).

> `PK` is a primary-key column and `FK` a declared foreign key. A solid
> line is a declared foreign key; a dashed line is a join the model
> intends but does not declare. The crow's foot is the "many" side.

## 1 · Core model

Two facts over conformed dimensions. A fact row holds the surrogate key of the dimension version current at load.

```mermaid
erDiagram
    dim_customer {
        INTEGER customer_key PK
        TEXT customer_ref
        TEXT customer_name
        TEXT email
        TEXT signup_date
        TEXT diff_str
        TEXT row_eff_ts
        TEXT row_exp_ts
        INTEGER is_current
        INTEGER is_deleted
    }
    dim_date {
        INTEGER date_key PK
        TEXT full_date
        INTEGER year
        INTEGER month
        TEXT month_name
        INTEGER day
        TEXT weekday
    }
    dim_order_status {
        INTEGER status_key PK
        TEXT status_code
        TEXT status_name
    }
    dim_product {
        INTEGER product_key PK
        TEXT sku
        TEXT product_name
        REAL price
        TEXT currency
        TEXT diff_str
        TEXT row_eff_ts
        TEXT row_exp_ts
        INTEGER is_current
        INTEGER is_deleted
    }
    fact_order_lines {
        TEXT order_ref PK
        INTEGER product_key PK, FK
        INTEGER placed_date_key FK
    }
    fact_orders {
        TEXT order_ref PK
        INTEGER placed_date_key FK
        INTEGER customer_key FK
        INTEGER status_key FK
        REAL amount
        TEXT currency
        TEXT placed_at
    }
    dim_date ||--o{ fact_order_lines : "placed_date_key"
    dim_product ||--o{ fact_order_lines : "product_key"
    dim_order_status ||--o{ fact_orders : "status_key"
    dim_customer ||--o{ fact_orders : "customer_key"
    dim_date ||--o{ fact_orders : "placed_date_key"
```

## 2 · Metadata and load control

Registries, routing maps and the parameters the loaders read.

```mermaid
erDiagram
    mart_load_params {
        TEXT batch_ts
    }
```

## 3 · Staging

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

## 4 · Raw layer (archive)

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
