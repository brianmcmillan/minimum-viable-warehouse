# `focal.db` — Entity-Relationship Diagrams

ER diagrams for the warehouse in [`build/focal.db`](../build/focal.db), generated from
the live schema. The database implements a **focal-point** (anchor-modeling / Data-Vault
style) model, so it is easier to read as a set of diagrams — one per architectural layer —
than as a single graph.

> **Reading the cardinalities.** Only the `meta_*` tables carry declared `FOREIGN KEY`s.
> All relationships in the *core* and *source* layers are **logical** — they are joins on
> surrogate keys (`*_key`) and semantic keys (`type_key`), not enforced constraints. They are
> drawn here to show intent. Columns marked `PK` are part of the SQLite primary key; `FK`
> marks a logical or declared foreign reference (noted in the column comment).

## Layers at a glance

```mermaid
flowchart TB
    subgraph SRC["1 · Source ingestion"]
        direction LR
        stage["source_landing_stage"] --> land["source_landing"]
    end
    subgraph META["2 · Metadata (model-driven catalog)"]
        direction LR
        ent["meta_entity"] --- ctx["meta_atomic_context"] --- rel["meta_relationship"]
    end
    subgraph CORE["3 · Core focal-point model"]
        direction LR
        idfr["*_idfr"] --- focal["*_focal"] --- desc["*_desc"] --- x["*_x"]
    end
    subgraph SEM["4 · Semantic views"]
        direction LR
        vw["v_customer / v_product / v_order / …"]
    end

    SRC -->|"loader (meta_source_map)"| CORE
    META -.->|"drives shape of"| CORE
    CORE --> SEM
```

---

## 1 · Conceptual (business) model

What the warehouse actually *means*, independent of the physical pattern. Derived from
`meta_entity`, `meta_relationship`, and the `v_*` views.

```mermaid
erDiagram
    CUSTOMER ||--o{ ORDER : "PLACED_BY"
    ORDER    }o--o{ PRODUCT : "CONTAINS"

    CUSTOMER {
        INTEGER customer_key PK "surrogate key"
        TEXT    customer_ref     "business identifier"
        TEXT    customer_name
        TEXT    email
        TEXT    signup_date
    }
    PRODUCT {
        INTEGER product_key PK "surrogate key"
        TEXT    sku            "business identifier"
        TEXT    product_name
        REAL    price
        TEXT    currency
    }
    ORDER {
        INTEGER order_key PK "surrogate key"
        TEXT    order_ref     "business identifier"
        TEXT    status
        REAL    amount
        TEXT    currency
        TEXT    placed_at
    }
```

- **PLACED_BY** — each order is placed by exactly one customer; a customer may place many
  orders. (`meta_relationship.type_key = 90`, resolved through `order_customer_x`.)
- **CONTAINS** — an order contains many products and a product appears on many orders.
  (`meta_relationship.type_key = 91`, resolved through `order_product_x`.)

---

## 2a · Core focal-point model — overview

Every business entity is stored as a **triad** of tables plus optional **`_x`** relationship
tables. Key columns only, so the overall shape is visible.

```mermaid
erDiagram
    customer_focal ||--o{ customer_idfr : "identified by"
    customer_focal ||--o{ customer_desc : "described by"
    product_focal  ||--o{ product_idfr  : "identified by"
    product_focal  ||--o{ product_desc  : "described by"
    order_focal    ||--o{ order_idfr    : "identified by"
    order_focal    ||--o{ order_desc    : "described by"

    order_focal    ||--o{ order_customer_x : "PLACED_BY"
    customer_focal ||--o{ order_customer_x : "places"
    order_focal    ||--o{ order_product_x  : "CONTAINS"
    product_focal  ||--o{ order_product_x  : "line item"

    customer_focal {
        INTEGER customer_key PK
    }
    customer_idfr {
        TEXT    customer_idfr PK "natural key"
        TEXT    eff_tmstp     PK
        TEXT    ver_tmstp     PK
        INTEGER customer_key  FK "-> customer_focal"
        TEXT    row_st           "Y active / N retired"
    }
    customer_desc {
        INTEGER customer_key PK "FK -> customer_focal"
        INTEGER type_key     PK "FK -> meta_atomic_context"
        TEXT    eff_tmstp    PK
        TEXT    ver_tmstp    PK
        TEXT    val_str
        REAL    val_num
    }
    product_focal {
        INTEGER product_key PK
    }
    product_idfr {
        TEXT    product_idfr PK "natural key (SKU)"
        TEXT    eff_tmstp    PK
        TEXT    ver_tmstp    PK
        INTEGER product_key  FK "-> product_focal"
        TEXT    row_st
    }
    product_desc {
        INTEGER product_key PK "FK -> product_focal"
        INTEGER type_key    PK "FK -> meta_atomic_context"
        TEXT    eff_tmstp   PK
        TEXT    ver_tmstp   PK
        TEXT    val_str
        REAL    val_num
    }
    order_focal {
        INTEGER order_key PK
    }
    order_idfr {
        TEXT    order_idfr PK "natural key"
        TEXT    eff_tmstp  PK
        TEXT    ver_tmstp  PK
        INTEGER order_key  FK "-> order_focal"
        TEXT    row_st
    }
    order_desc {
        INTEGER order_key PK "FK -> order_focal"
        INTEGER type_key  PK "FK -> meta_atomic_context"
        TEXT    eff_tmstp PK
        TEXT    ver_tmstp PK
        TEXT    val_str
        REAL    val_num
    }
    order_customer_x {
        INTEGER order_key    PK "FK -> order_focal"
        INTEGER customer_key PK "FK -> customer_focal"
        INTEGER type_key     PK "FK -> meta_relationship (90)"
        TEXT    eff_tmstp    PK
        TEXT    ver_tmstp    PK
        TEXT    row_st
    }
    order_product_x {
        INTEGER order_key   PK "FK -> order_focal"
        INTEGER product_key PK "FK -> product_focal"
        INTEGER type_key    PK "FK -> meta_relationship (91)"
        TEXT    eff_tmstp   PK
        TEXT    ver_tmstp   PK
        TEXT    row_st
    }
```

**The triad pattern (identical for customer / product / order):**

| Table       | Role                | Anchor-modeling term | Holds                                                   |
|-------------|---------------------|----------------------|---------------------------------------------------------|
| `*_focal`   | the entity itself   | anchor / hub         | one row per surrogate `*_key` — the point of reference  |
| `*_idfr`    | natural-key map     | (hub key) identifier | business identifier ⇄ surrogate key, bi-temporal        |
| `*_desc`    | attributes          | attribute / satellite| one fact per `type_key`, versioned over time            |
| `*_x`       | relationship        | tie / link           | connects two focals under a relationship `type_key`     |

---

## 2b · Anchor triad — full column detail (CUSTOMER)

Every core table carries the same bi-temporal + audit columns. This is the complete
`customer_*` triad; `product_*` and `order_*` are structurally identical.

```mermaid
erDiagram
    customer_focal ||--o{ customer_idfr : "identified by"
    customer_focal ||--o{ customer_desc : "described by"

    customer_focal {
        INTEGER customer_key PK "surrogate key -- one row per customer"
        TEXT    eff_tmstp       "effective from"
        TEXT    ver_tmstp       "version (bi-temporal tie-breaker)"
        TEXT    row_st          "Y active / N retired"
        INTEGER data_key        "hash / dedup key"
        INTEGER inst_key        "FK -> meta_procinst (load run)"
        INTEGER inst_row_key    "row ordinal within the run"
        TEXT    popln_tmstp     "physical insert time"
    }
    customer_idfr {
        TEXT    customer_idfr PK "business identifier as seen in source"
        TEXT    eff_tmstp     PK "when this identifier became effective"
        TEXT    ver_tmstp     PK "version tie-breaker"
        TEXT    row_st           "Y active / N retired"
        INTEGER customer_key     "FK -> customer_focal.customer_key"
        INTEGER data_key
        INTEGER inst_key         "FK -> meta_procinst"
        INTEGER inst_row_key
        TEXT    popln_tmstp
    }
    customer_desc {
        INTEGER customer_key PK "FK -> customer_focal.customer_key"
        INTEGER type_key     PK "FK -> meta_atomic_context.type_key (the semantic key)"
        TEXT    eff_tmstp    PK "effective from"
        TEXT    ver_tmstp    PK "version tie-breaker"
        INTEGER seq_nbr         "multi-value ordinal (default 0)"
        TEXT    row_st          "Y active / N logically deleted"
        TEXT    sta_tmstp       "generic: start / from timestamp"
        TEXT    end_tmstp       "generic: end / to timestamp"
        TEXT    val_str         "generic: string value"
        REAL    val_num         "generic: numeric value"
        TEXT    uom             "generic: unit / qualifier (e.g. currency)"
        INTEGER data_key
        INTEGER inst_key        "FK -> meta_procinst"
        INTEGER inst_row_key
        TEXT    popln_tmstp
    }
```

> `*_desc` is a **narrow/tall** store: instead of one wide column per attribute, each fact is
> a row tagged by `type_key`. The physical column used (`val_str` / `val_num` / `sta_tmstp` /
> `uom`) is chosen per `type_key` by `meta_attribute.phys_column`.

---

## 3 · Metadata layer (model-driven catalog)

These tables *define* the model above and drive the loader. All relationships here are
**declared foreign keys**.

```mermaid
erDiagram
    meta_entity          ||--o{ meta_atomic_context : "has facts"
    meta_atomic_context  ||--o{ meta_attribute      : "physical columns"
    meta_atomic_context  ||--o{ meta_value_map      : "value crosswalk"
    meta_entity          ||--o{ meta_relationship   : "as source"
    meta_entity          ||--o{ meta_relationship   : "as target"
    meta_relationship    ||--o| meta_rel_map        : "key resolution"
    meta_entity          ||--o{ meta_source_map     : "sourced by"
    meta_atomic_context  ||--o{ meta_source_map     : "attr mapping"
    meta_source_feed     ||--o{ meta_source_map     : "delivered by"

    meta_entity {
        TEXT entity_id  PK "CUSTOMER / PRODUCT / ORDER"
        TEXT definition
        TEXT key_col       "name of the surrogate key column"
    }
    meta_atomic_context {
        INTEGER type_key     PK "the semantic key used across core tables"
        TEXT    entity_id    FK "-> meta_entity"
        TEXT    context_name    "e.g. CUSTOMER_EMAIL"
        TEXT    definition
    }
    meta_attribute {
        INTEGER type_key    PK "FK -> meta_atomic_context"
        TEXT    attr_name   PK
        TEXT    phys_column    "VAL_STR / VAL_NUM / STA_TMSTP / UOM"
        TEXT    data_type
    }
    meta_relationship {
        INTEGER type_key      PK "e.g. 90 PLACED_BY, 91 CONTAINS"
        TEXT    rel_name
        TEXT    source_entity FK "-> meta_entity"
        TEXT    target_entity FK "-> meta_entity"
        TEXT    x_table          "target relationship table"
    }
    meta_rel_map {
        INTEGER type_key        PK "FK -> meta_relationship"
        TEXT    source_system
        TEXT    source_entity
        TEXT    source_key_attr    "natural key on source side"
        TEXT    target_key_attr    "natural key on target side"
    }
    meta_value_map {
        INTEGER type_key     PK "FK -> meta_atomic_context"
        TEXT    source_value PK
        TEXT    target_value
    }
    meta_source_feed {
        TEXT source_system      PK
        TEXT source_entity      PK
        TEXT ingestion_strategy    "FULL | INCREMENTAL"
    }
    meta_source_map {
        INTEGER map_id           PK
        TEXT    entity_id        FK "-> meta_entity"
        INTEGER type_key         FK "-> meta_atomic_context (nullable)"
        TEXT    source_system
        TEXT    source_entity
        TEXT    role                "IDFR | DESC | ..."
        TEXT    source_attribute
        TEXT    phys_column
        TEXT    default_value
    }
    meta_procinst {
        INTEGER inst_key   PK "load-run id (AUTOINCREMENT)"
        TEXT    pipeline
        TEXT    batch_ts
        TEXT    sql_text      "generated SQL for the run"
        TEXT    run_tmstp
    }
```

> `meta_procinst` has no FK partners here, but every core row carries its `inst_key`
> (`*_focal` / `*_idfr` / `*_desc` / `*_x`), giving full **load lineage** back to the run
> that produced it (see `v_lineage`).

---

## 4 · Source ingestion layer

The generic landing zone. Sources deliver **one row per (business key, attribute)** as
key/value pairs — the same tall shape the core uses.

```mermaid
erDiagram
    meta_source_feed        ||--o{ source_landing_stage : "governs delivery"
    source_landing_stage    ||--|| source_landing       : "promoted (same shape)"

    meta_source_feed {
        TEXT source_system      PK
        TEXT source_entity      PK
        TEXT ingestion_strategy    "FULL | INCREMENTAL"
    }
    source_landing_stage {
        TEXT source_system
        TEXT source_entity
        TEXT business_key
        TEXT attribute_name
        TEXT value_str
        REAL value_num
        TEXT value_ts
        TEXT extract_ts
        TEXT op            "UPSERT | DELETE (tombstone)"
        TEXT load_mode     "FULL | INCREMENTAL"
    }
    source_landing {
        TEXT source_system
        TEXT source_entity
        TEXT business_key
        TEXT attribute_name
        TEXT value_str
        REAL value_num
        TEXT value_ts
        TEXT extract_ts
        TEXT op            "UPSERT | DELETE (tombstone)"
        TEXT load_mode     "FULL | INCREMENTAL"
    }
```

- `source_landing_stage` and `source_landing` are structural twins: staged deliveries are
  promoted into `source_landing` (indexed on `source_system, source_entity, attribute_name`).
- `meta_source_map` (metadata layer) then maps each landed `(source_entity, attribute_name)`
  onto a target `entity_id` + `type_key` in the core, and `meta_source_feed.ingestion_strategy`
  decides FULL vs INCREMENTAL handling. See [`INCREMENTAL.md`](../INCREMENTAL.md).

---

## 5 · Semantic views — lineage (supplementary)

Not an ER diagram (views have no keys), but this shows how the `v_*` views reassemble the
generic core into business-shaped rows.

```mermaid
flowchart LR
    classDef base fill:#e8f0fe,stroke:#4a72c4,color:#1a1a1a;
    classDef vw   fill:#e6f4ea,stroke:#34a853,color:#1a1a1a;

    customer_desc:::base --> v_customer_desc_current:::vw
    product_desc:::base  --> v_product_desc_current:::vw
    order_desc:::base    --> v_order_desc_current:::vw

    customer_focal:::base --> v_customer:::vw
    customer_idfr:::base  --> v_customer
    v_customer_desc_current --> v_customer

    product_focal:::base --> v_product:::vw
    product_idfr:::base  --> v_product
    v_product_desc_current --> v_product

    order_focal:::base   --> v_order:::vw
    order_idfr:::base    --> v_order
    v_order_desc_current --> v_order
    order_customer_x:::base --> v_order
    v_customer --> v_order

    v_customer_desc_current --> v_all_facts:::vw
    v_product_desc_current  --> v_all_facts
    v_order_desc_current    --> v_all_facts
    meta_atomic_context:::base --> v_all_facts

    order_desc --> v_order_status_history:::vw
    order_idfr --> v_order_status_history

    order_desc --> v_lineage:::vw
    meta_atomic_context --> v_lineage
    meta_procinst:::base --> v_lineage
```

| View                       | Purpose                                                        |
|----------------------------|----------------------------------------------------------------|
| `v_*_desc_current`         | latest active fact per (`*_key`, `type_key`)                    |
| `v_customer/v_product/v_order` | one readable row per entity (pivots `type_key` → columns)  |
| `v_all_facts`              | every current atomic fact across all entities, long form       |
| `v_order_status_history`   | full version history of order status (`type_key = 30`)         |
| `v_lineage`                | each order fact traced back to its load run (`meta_procinst`)  |

---

<sub>Generated from the live schema of `build/focal.db`. Regenerate with
`sqlite3 build/focal.db .schema` after schema changes.</sub>
