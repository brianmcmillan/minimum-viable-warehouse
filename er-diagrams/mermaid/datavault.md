# Data Vault 2.0 — ER diagrams

Generated from [`v3_datavault/build/datavault.db`](../../v3_datavault/build/datavault.db) by `er-diagrams/generate.py`. Design notes: [`v3_datavault/DATAVAULT.md`](../../v3_datavault/DATAVAULT.md).

> `PK` is a primary-key column and `FK` a declared foreign key. A solid
> line is a declared foreign key; a dashed line is a join the model
> intends but does not declare. The crow's foot is the "many" side.

## 1 · Core model

Hubs (`_h`), links (`_l`), satellites (`_hsat`), status satellites (`_sts`) and one effectivity satellite. The insert-only raw vault is its own durable layer, so there is no archive database.

```mermaid
erDiagram
    bv_order_customer_l_effsat {
        TEXT order_bk PK, FK
        TEXT customer_bk PK, FK
        TEXT ldts PK
        TEXT rsrc
        TEXT start_date
        TEXT old_customer_bk
    }
    rv_customer_h {
        TEXT customer_bk PK
        TEXT ldts
        TEXT rsrc
    }
    rv_customer_hsat {
        TEXT customer_bk PK, FK
        TEXT ldts PK
        TEXT rsrc
        TEXT diff_str
        TEXT full_name
        TEXT email_addr
        TEXT signup_date
    }
    rv_customer_sts {
        TEXT customer_bk PK, FK
        TEXT ldts PK
        TEXT rsrc
        TEXT sts
    }
    rv_order_customer_l {
        TEXT order_bk PK, FK
        TEXT customer_bk PK, FK
        TEXT ldts
        TEXT rsrc
    }
    rv_order_h {
        TEXT order_bk PK
        TEXT ldts
        TEXT rsrc
    }
    rv_order_hsat {
        TEXT order_bk PK, FK
        TEXT ldts PK
        TEXT rsrc
        TEXT diff_str
        TEXT status
        REAL amount
        TEXT currency
        TEXT placed_at
    }
    rv_order_product_l {
        TEXT order_bk PK, FK
        TEXT product_bk PK, FK
        TEXT ldts
        TEXT rsrc
    }
    rv_order_sts {
        TEXT order_bk PK, FK
        TEXT ldts PK
        TEXT rsrc
        TEXT sts
    }
    rv_product_h {
        TEXT product_bk PK
        TEXT ldts
        TEXT rsrc
    }
    rv_product_hsat {
        TEXT product_bk PK, FK
        TEXT ldts PK
        TEXT rsrc
        TEXT diff_str
        TEXT prod_name
        REAL price
        TEXT currency
    }
    rv_product_sts {
        TEXT product_bk PK, FK
        TEXT ldts PK
        TEXT rsrc
        TEXT sts
    }
    rv_order_customer_l ||--o{ bv_order_customer_l_effsat : "order_bk, customer_bk"
    rv_customer_h ||--o{ rv_customer_hsat : "customer_bk"
    rv_customer_h ||--o{ rv_customer_sts : "customer_bk"
    rv_customer_h ||--o{ rv_order_customer_l : "customer_bk"
    rv_order_h ||--o{ rv_order_customer_l : "order_bk"
    rv_order_h ||--o{ rv_order_hsat : "order_bk"
    rv_product_h ||--o{ rv_order_product_l : "product_bk"
    rv_order_h ||--o{ rv_order_product_l : "order_bk"
    rv_order_h ||--o{ rv_order_sts : "order_bk"
    rv_product_h ||--o{ rv_product_hsat : "product_bk"
    rv_product_h ||--o{ rv_product_sts : "product_bk"
```

## 2 · Metadata and load control

Registries, routing maps and the parameters the loaders read.

```mermaid
erDiagram
    dv_load_audit {
        TEXT file_id PK
        INTEGER load_seq
        TEXT batch_ts
        TEXT status
        TEXT loaded_at
        INTEGER row_count
    }
    dv_load_params {
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
