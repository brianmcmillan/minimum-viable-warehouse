# HOOK — ER diagrams

Generated from [`v3_hook/build/hook.db`](../../v3_hook/build/hook.db) and `archive/hook_archive.db` by `er-diagrams/generate.py`. Design notes: [`v3_hook/HOOK.md`](../../v3_hook/HOOK.md).

> `PK` is a primary-key column and `FK` a declared foreign key. A solid
> line is a declared foreign key; a dashed line is a join the model
> intends but does not declare. The crow's foot is the "many" side.

This model declares none of its relationships as foreign keys, so 4 dashed lines were added by hand in the generator.

## 1 · Core model

One frame per source table. Frames relate only by carrying the same hook value, so the lines here are joins on `hk_` columns, not constraints.

```mermaid
erDiagram
    frame__crm__customer {
        TEXT hk_customer PK
        TEXT customer_id
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
    frame__oms__order {
        TEXT hk_order PK
        TEXT hk_customer
        TEXT order_ref
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
    frame__oms__order_line {
        TEXT hk_order PK
        TEXT hk_product PK
        TEXT order_ref
        TEXT sku
        TEXT extract_dt
        TEXT change_type
        TEXT delete_basis
        TEXT diff_str
        TEXT load_ts PK
        TEXT record_source
    }
    frame__pim__product {
        TEXT hk_product PK
        TEXT sku
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
    ref_oms_order_status {
        TEXT status_code PK
        TEXT status_name
    }
    frame__crm__customer ||..o{ frame__oms__order : "hk_customer"
    frame__oms__order ||..o{ frame__oms__order_line : "hk_order"
    frame__pim__product ||..o{ frame__oms__order_line : "hk_product"
    ref_oms_order_status ||..o{ frame__oms__order : "status"
```

## 2 · Metadata and load control

Registries, routing maps and the parameters the loaders read.

```mermaid
erDiagram
    hook_column {
        TEXT frame PK, FK
        TEXT hook_column PK
        TEXT keyset FK
    }
    hook_concept {
        TEXT concept PK
        TEXT description
    }
    hook_frame {
        TEXT frame PK
        INTEGER load_order
        TEXT stage_table
        TEXT stage_view
        TEXT frame_key
        TEXT bk_columns
        TEXT description
    }
    hook_keyset {
        TEXT keyset PK
        TEXT concept FK
        TEXT source_system
        TEXT description
    }
    hook_load_params {
        TEXT batch_ts
        TEXT file_id
    }
    hook_keyset ||--o{ hook_column : "keyset"
    hook_frame ||--o{ hook_column : "frame"
    hook_concept ||--o{ hook_keyset : "concept"
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
