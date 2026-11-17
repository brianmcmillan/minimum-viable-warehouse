# Focal Point — ER diagrams

Generated from [`v3_focal-point/build/focal.db`](../../v3_focal-point/build/focal.db) and `archive/focal_archive.db` by `er-diagrams/generate.py`. Design notes: [`v3_focal-point/FOCALPOINT.md`](../../v3_focal-point/FOCALPOINT.md).

> `PK` is a primary-key column and `FK` a declared foreign key. A solid
> line is a declared foreign key; a dashed line is a join the model
> intends but does not declare. The crow's foot is the "many" side.

This model declares none of its relationships as foreign keys, so 10 dashed lines were added by hand in the generator.

## 1 · Core model

Three generic tables per entity (`_idfr`, `_focal`, `_desc`) and one `_x` table per relationship. The core declares no foreign keys; `type_key` values are defined in the metadata.

```mermaid
erDiagram
    customer_desc {
        INTEGER customer_key PK
        INTEGER type_key PK
        TEXT eff_tmstp PK
        TEXT ver_tmstp PK
        INTEGER seq_nbr
        TEXT row_st
        TEXT sta_tmstp
        TEXT end_tmstp
        TEXT val_str
        REAL val_num
        TEXT uom
        INTEGER data_key
        INTEGER inst_key
        INTEGER inst_row_key
        TEXT popln_tmstp
    }
    customer_focal {
        INTEGER customer_key PK
        TEXT eff_tmstp
        TEXT ver_tmstp
        TEXT row_st
        INTEGER data_key
        INTEGER inst_key
        INTEGER inst_row_key
        TEXT popln_tmstp
    }
    customer_idfr {
        TEXT customer_idfr PK
        TEXT eff_tmstp PK
        TEXT ver_tmstp PK
        TEXT row_st
        INTEGER customer_key
        INTEGER data_key
        INTEGER inst_key
        INTEGER inst_row_key
        TEXT popln_tmstp
    }
    order_customer_x {
        INTEGER order_key PK
        INTEGER customer_key PK
        INTEGER type_key PK
        TEXT eff_tmstp PK
        TEXT ver_tmstp PK
        TEXT row_st
        INTEGER data_key
        INTEGER inst_key
        INTEGER inst_row_key
        TEXT popln_tmstp
    }
    order_desc {
        INTEGER order_key PK
        INTEGER type_key PK
        TEXT eff_tmstp PK
        TEXT ver_tmstp PK
        INTEGER seq_nbr
        TEXT row_st
        TEXT sta_tmstp
        TEXT end_tmstp
        TEXT val_str
        REAL val_num
        TEXT uom
        INTEGER data_key
        INTEGER inst_key
        INTEGER inst_row_key
        TEXT popln_tmstp
    }
    order_focal {
        INTEGER order_key PK
        TEXT eff_tmstp
        TEXT ver_tmstp
        TEXT row_st
        INTEGER data_key
        INTEGER inst_key
        INTEGER inst_row_key
        TEXT popln_tmstp
    }
    order_idfr {
        TEXT order_idfr PK
        TEXT eff_tmstp PK
        TEXT ver_tmstp PK
        TEXT row_st
        INTEGER order_key
        INTEGER data_key
        INTEGER inst_key
        INTEGER inst_row_key
        TEXT popln_tmstp
    }
    order_product_x {
        INTEGER order_key PK
        INTEGER product_key PK
        INTEGER type_key PK
        TEXT eff_tmstp PK
        TEXT ver_tmstp PK
        TEXT row_st
        INTEGER data_key
        INTEGER inst_key
        INTEGER inst_row_key
        TEXT popln_tmstp
    }
    product_desc {
        INTEGER product_key PK
        INTEGER type_key PK
        TEXT eff_tmstp PK
        TEXT ver_tmstp PK
        INTEGER seq_nbr
        TEXT row_st
        TEXT sta_tmstp
        TEXT end_tmstp
        TEXT val_str
        REAL val_num
        TEXT uom
        INTEGER data_key
        INTEGER inst_key
        INTEGER inst_row_key
        TEXT popln_tmstp
    }
    product_focal {
        INTEGER product_key PK
        TEXT eff_tmstp
        TEXT ver_tmstp
        TEXT row_st
        INTEGER data_key
        INTEGER inst_key
        INTEGER inst_row_key
        TEXT popln_tmstp
    }
    product_idfr {
        TEXT product_idfr PK
        TEXT eff_tmstp PK
        TEXT ver_tmstp PK
        TEXT row_st
        INTEGER product_key
        INTEGER data_key
        INTEGER inst_key
        INTEGER inst_row_key
        TEXT popln_tmstp
    }
    customer_focal ||..o{ customer_idfr : "customer_key"
    order_focal ||..o{ order_idfr : "order_key"
    product_focal ||..o{ product_idfr : "product_key"
    customer_focal ||..o{ customer_desc : "customer_key"
    order_focal ||..o{ order_desc : "order_key"
    product_focal ||..o{ product_desc : "product_key"
    order_focal ||..o{ order_customer_x : "order_key"
    customer_focal ||..o{ order_customer_x : "customer_key"
    order_focal ||..o{ order_product_x : "order_key"
    product_focal ||..o{ order_product_x : "product_key"
```

## 2 · Metadata and load control

Registries, routing maps and the parameters the loaders read.

```mermaid
erDiagram
    meta_atomic_context {
        INTEGER type_key PK
        TEXT entity_id FK
        TEXT context_name
        TEXT definition
    }
    meta_attribute {
        INTEGER type_key PK, FK
        TEXT attr_name PK
        TEXT phys_column
        TEXT data_type
    }
    meta_entity {
        TEXT entity_id PK
        TEXT definition
        TEXT key_col
    }
    meta_procinst {
        INTEGER inst_key PK
        TEXT pipeline
        TEXT batch_ts
        TEXT sql_text
        TEXT run_tmstp
    }
    meta_rel_map {
        INTEGER type_key PK, FK
        TEXT source_system
        TEXT source_entity
        TEXT source_key_attr
        TEXT target_key_attr
    }
    meta_relationship {
        INTEGER type_key PK
        TEXT rel_name
        TEXT source_entity FK
        TEXT target_entity FK
        TEXT x_table
    }
    meta_source_feed {
        TEXT source_system PK
        TEXT source_entity PK
        TEXT ingestion_strategy
    }
    meta_source_map {
        INTEGER map_id PK
        TEXT entity_id
        INTEGER type_key
        TEXT source_system
        TEXT source_entity
        TEXT role
        TEXT source_attribute
        TEXT phys_column
        TEXT default_value
    }
    meta_value_map {
        INTEGER type_key PK
        TEXT source_value PK
        TEXT target_value
    }
    meta_entity ||--o{ meta_atomic_context : "entity_id"
    meta_atomic_context ||--o{ meta_attribute : "type_key"
    meta_relationship ||--o| meta_rel_map : "type_key"
    meta_entity ||--o{ meta_relationship : "target_entity"
    meta_entity ||--o{ meta_relationship : "source_entity"
```

## 3 · Staging

Where a delivery lands before it is applied. Staging tables hold source names, so they have no relationships.

```mermaid
erDiagram
    source_landing {
        TEXT source_system
        TEXT source_entity
        TEXT business_key
        TEXT attribute_name
        TEXT value_str
        REAL value_num
        TEXT value_ts
        TEXT extract_ts
        TEXT op
        TEXT load_mode
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
        TEXT op
        TEXT load_mode
    }
```

## 4 · Raw layer (archive)

The durable raw layer, in its own database file. Every delivery is captured here verbatim before it is applied, and the tables are append-only.

```mermaid
erDiagram
    loaded_files {
        TEXT file_id PK
        INTEGER load_seq
        TEXT batch_ts
        TEXT status
        TEXT loaded_at
        INTEGER row_count
    }
    source_landing_history {
        TEXT file_id PK, FK
        INTEGER load_seq
        TEXT batch_ts
        INTEGER seq_nbr PK
        TEXT source_system
        TEXT source_entity
        TEXT business_key
        TEXT attribute_name
        TEXT value_str
        REAL value_num
        TEXT value_ts
        TEXT extract_ts
        TEXT op
        TEXT load_mode
        TEXT archived_at
    }
    loaded_files ||--o{ source_landing_history : "file_id"
```
