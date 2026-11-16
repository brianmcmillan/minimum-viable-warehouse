# Activity Schema — ER diagrams

Generated from [`v3_activity-schema/build/activity.db`](../../v3_activity-schema/build/activity.db) and `archive/activity_archive.db` by `er-diagrams/generate.py`. Design notes: [`v3_activity-schema/ACTIVITY.md`](../../v3_activity-schema/ACTIVITY.md).

> `PK` is a primary-key column and `FK` a declared foreign key. A solid
> line is a declared foreign key; a dashed line is a join the model
> intends but does not declare. The crow's foot is the "many" side.

## 1 · Core model

Two streams with the same fixed columns. Activities relate by who (`customer`), what (`link`) and when (`ts`), so there is nothing to draw between them. The order status code lives inside `feature_json` and is decoded on read.

```mermaid
erDiagram
    customer_stream {
        TEXT activity_id PK
        TEXT ts
        TEXT customer
        TEXT activity
        TEXT anonymous_customer_id
        TEXT feature_json
        REAL revenue_impact
        TEXT link
        INTEGER _seq
        TEXT _load_ts
        TEXT _record_source
    }
    product_stream {
        TEXT activity_id PK
        TEXT ts
        TEXT customer
        TEXT activity
        TEXT anonymous_customer_id
        TEXT feature_json
        REAL revenue_impact
        TEXT link
        INTEGER _seq
        TEXT _load_ts
        TEXT _record_source
    }
    ref_oms_order_status {
        TEXT status_code PK
        TEXT status_name
    }
```

## 2 · Metadata and load control

Registries, routing maps and the parameters the loaders read.

```mermaid
erDiagram
    act_load_params {
        TEXT batch_ts
        TEXT file_id
    }
    activity_catalog {
        TEXT stream PK
        TEXT activity PK
        TEXT ts_source
        TEXT meaning
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
