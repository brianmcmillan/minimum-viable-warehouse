# Inmon 3NF EDW — ER diagrams

Generated from [`v3_inmon-3nf/build/edw.db`](../../v3_inmon-3nf/build/edw.db) and `archive/edw_archive.db` by `er-diagrams/generate.py`. Design notes: [`v3_inmon-3nf/INMON.md`](../../v3_inmon-3nf/INMON.md).

> `PK` is a primary-key column and `FK` a declared foreign key. A solid
> line is a declared foreign key; a dashed line is a join the model
> intends but does not declare. The crow's foot is the "many" side.

This model declares none of its relationships as foreign keys, so 4 dashed lines were added by hand in the generator.

## 1 · Core model

Time-variant entities keyed on the natural key plus `valid_from`. The model declares no foreign keys, because a reference is to an entity and not to one of its versions.

```mermaid
erDiagram
    customer {
        TEXT customer_ref PK
        TEXT full_name
        TEXT email
        TEXT signup_date
        TEXT diff_str
        TEXT valid_from PK
        TEXT valid_to
        INTEGER is_current
        INTEGER is_deleted
    }
    order_line {
        TEXT order_ref PK
        TEXT sku PK
        TEXT valid_from
    }
    order_status_ref {
        TEXT status_code PK
        TEXT status_name
    }
    orders {
        TEXT order_ref PK
        TEXT customer_ref
        TEXT status
        REAL amount
        TEXT currency
        TEXT placed_at
        TEXT diff_str
        TEXT valid_from PK
        TEXT valid_to
        INTEGER is_current
        INTEGER is_deleted
    }
    product {
        TEXT sku PK
        TEXT product_name
        REAL price
        TEXT currency
        TEXT diff_str
        TEXT valid_from PK
        TEXT valid_to
        INTEGER is_current
        INTEGER is_deleted
    }
    customer ||..o{ orders : "customer_ref"
    orders ||..o{ order_line : "order_ref"
    product ||..o{ order_line : "sku"
    order_status_ref ||..o{ orders : "status"
```

## 2 · Metadata and load control

Registries, routing maps and the parameters the loaders read.

```mermaid
erDiagram
    edw_load_params {
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
