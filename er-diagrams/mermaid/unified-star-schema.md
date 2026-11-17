# Unified Star Schema — ER diagrams

Generated from [`v3_unified-star-schema/build/uss.db`](../../v3_unified-star-schema/build/uss.db) and `archive/uss_archive.db` by `er-diagrams/generate.py`. Design notes: [`v3_unified-star-schema/USS.md`](../../v3_unified-star-schema/USS.md).

> `PK` is a primary-key column and `FK` a declared foreign key. A solid
> line is a declared foreign key; a dashed line is a join the model
> intends but does not declare. The crow's foot is the "many" side.

This model declares none of its relationships as foreign keys, so 8 dashed lines were added by hand in the generator.

## 1 · Insert-only core

History lives here. The Unified Star Schema is a presentation model, so this demo puts it on a core of its own.

```mermaid
erDiagram
    core_customer {
        TEXT customer_id PK
        TEXT full_name
        TEXT email_addr
        TEXT signup_date
        TEXT extract_dt
        TEXT change_type
        TEXT delete_basis
        TEXT diff_str
        TEXT load_ts PK
        TEXT record_source
    }
    core_order {
        TEXT order_ref PK
        TEXT customer_ref
        TEXT status
        REAL amount
        TEXT currency
        TEXT placed_at
        TEXT extract_dt
        TEXT change_type
        TEXT delete_basis
        TEXT diff_str
        TEXT load_ts PK
        TEXT record_source
    }
    core_order_line {
        TEXT order_ref PK
        TEXT sku PK
        TEXT extract_dt
        TEXT change_type
        TEXT delete_basis
        TEXT diff_str
        TEXT load_ts PK
        TEXT record_source
    }
    core_product {
        TEXT sku PK
        TEXT prod_name
        REAL price
        TEXT currency
        TEXT extract_dt
        TEXT change_type
        TEXT delete_basis
        TEXT diff_str
        TEXT load_ts PK
        TEXT record_source
    }
    core_customer ||..o{ core_order : "customer_ref"
    core_order ||..o{ core_order_line : "order_ref"
    core_product ||..o{ core_order_line : "sku"
```

## 2 · Unified Star Schema (presentation layer)

Re-derived from the core after every delivery. Every table joins only to the bridge, through its own `_key_` column.

```mermaid
erDiagram
    customer {
        TEXT _key_customer PK
        TEXT customer_ref
        TEXT customer_name
        TEXT email
        TEXT signup_date
    }
    product {
        TEXT _key_product PK
        TEXT sku
        TEXT product_name
        REAL price
        TEXT currency
    }
    orders {
        TEXT _key_orders PK
        TEXT order_ref
        TEXT status
        TEXT status_code
        REAL amount
        TEXT currency
        TEXT placed_at
    }
    order_line {
        TEXT _key_order_line PK
        TEXT order_ref
        TEXT sku
    }
    T_bridge["_bridge"] {
        TEXT stage
        TEXT _key_customer
        TEXT _key_product
        TEXT _key_orders
        TEXT _key_order_line
        REAL order_amount
        INTEGER line_count
    }
    ref_order_status {
        TEXT status_code PK
        TEXT status_name
    }
    customer ||..o{ T_bridge : "_key_customer"
    product ||..o{ T_bridge : "_key_product"
    orders ||..o{ T_bridge : "_key_orders"
    order_line ||..o{ T_bridge : "_key_order_line"
    ref_order_status ||..o{ orders : "status_code"
```

## 3 · Metadata and load control

Registries, routing maps and the parameters the loaders read.

```mermaid
erDiagram
    core_table {
        TEXT core_table PK
        INTEGER load_order
        TEXT stage_table
        TEXT stage_view
        TEXT table_key
    }
    load_params {
        TEXT batch_ts
        TEXT file_id
    }
    uss_refresh {
        TEXT refreshed_for_load_ts
        TEXT record_source
    }
```

## 4 · Staging

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

## 5 · Raw layer (archive)

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
