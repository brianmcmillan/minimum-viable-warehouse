# `metrics.db` — Entity-Relationship Diagrams

ER diagrams for the mart in [`build/metrics.db`](../build/metrics.db),
generated from the live schema. Every column, type, primary key and
foreign key below comes from SQLite's own catalogue, so the diagrams match
what `make demo` builds.

The mart has 19 tables plus five staging tables, not counting the landing
and routing metadata. One graph of all of them is too wide to read, so there is a keys-only overview and
then one full-column diagram per layer.

> **Reading the diagrams.** `PK` marks a primary-key column and `FK` a
> declared foreign key; every foreign key here is enforced. A line ending
> in a crow's foot is the "many" side. `||` means the reference is
> required and `|o` means it may be null. A table that appears outside its
> own layer (for example `RES` in the metrics diagram) shows its key
> columns only.

## Overview — keys only

Every table that has a relationship, with its key columns. On GitHub, use
the diagram's zoom and pan controls.

```mermaid
erDiagram
    RES_TYPE {
        CHAR(12) res_type PK
    }
    RES_TYPE_REL {
        CHAR(12) parent_res_type PK, FK
        CHAR(12) child_res_type PK, FK
        CHAR(1) res_type_rel PK
    }
    RES {
        INTEGER res_id PK
        CHAR(12) res_type FK
        INTEGER parent_res FK
    }
    RES_ALIAS {
        CHAR(12) res_type PK, FK
        VARCHAR(128) res_alias PK
        INTEGER res_id FK
    }
    RES_GRP {
        INTEGER res_grp_id PK
        INTEGER parent_res_grp FK
    }
    RES_RESGRP {
        INTEGER res_grp_id PK, FK
        INTEGER res_id PK, FK
    }
    VALUE_TYPE {
        CHAR(8) value_type PK
    }
    METRIC {
        INTEGER metric_id PK
        CHAR(8) value_type FK
    }
    PROVIDER {
        INTEGER provider_id PK
    }
    METRIC_SAMPLE {
        INTEGER res_id PK, FK
        INTEGER metric_id PK, FK
        TIMESTAMP sample_utc_ts PK
        INTEGER provider_id PK, FK
    }
    METRIC_SUMMARY {
        INTEGER res_id PK, FK
        INTEGER metric_id PK, FK
        CHAR(1) summary_level PK
        TIMESTAMP start_utc_ts PK
        INTEGER provider_id PK, FK
    }
    METRIC_WEEKLY {
        INTEGER res_id PK, FK
        INTEGER metric_id PK, FK
        DATE start_lcl_dt PK
        INTEGER provider_id PK, FK
    }
    GRP_METRIC_WEEKLY {
        INTEGER res_id PK, FK
        INTEGER res_grp_id PK, FK
        INTEGER metric_id PK, FK
        DATE start_lcl_dt PK
        INTEGER provider_id PK, FK
    }
    RES_TYPE ||--o{ RES_TYPE_REL : "may be child"
    RES_TYPE ||--o{ RES_TYPE_REL : "may parent"
    RES |o--o{ RES : "parent of"
    RES_TYPE ||--o{ RES : "classifies"
    RES ||--o{ RES_ALIAS : "is known as"
    RES_TYPE ||--o{ RES_ALIAS : "scopes"
    RES_GRP |o--o{ RES_GRP : "parent of"
    RES ||--o{ RES_RESGRP : "belongs to"
    RES_GRP ||--o{ RES_RESGRP : "has member"
    VALUE_TYPE ||--o{ METRIC : "types"
    PROVIDER ||--o{ METRIC_SAMPLE : "reports"
    METRIC ||--o{ METRIC_SAMPLE : "is observed as"
    RES ||--o{ METRIC_SAMPLE : "is measured by"
    PROVIDER ||--o{ METRIC_SUMMARY : "reports"
    METRIC ||--o{ METRIC_SUMMARY : "is summarised as"
    RES ||--o{ METRIC_SUMMARY : "is summarised by"
    PROVIDER ||--o{ METRIC_WEEKLY : "reports"
    METRIC ||--o{ METRIC_WEEKLY : "rolls up as"
    RES ||--o{ METRIC_WEEKLY : "rolls up to"
    PROVIDER ||--o{ GRP_METRIC_WEEKLY : "reports"
    METRIC ||--o{ GRP_METRIC_WEEKLY : "rolls up as"
    RES_GRP ||--o{ GRP_METRIC_WEEKLY : "rolls up"
    RES ||--o{ GRP_METRIC_WEEKLY : "rolls up in"
```

---

## 1 · Resources and groups

What exists. `RES` holds every resource of every type. `RES_ALIAS` maps
each name a provider uses to a `res_id`. `RES_GRP` is a hierarchy stored
as a path, and `RES_RESGRP` puts resources in groups.

```mermaid
erDiagram
    RES_TYPE {
        CHAR(12) res_type PK
        VARCHAR(100) res_type_desc
        SMALLINT autocrt_res_flag
        TIMESTAMP srcd_ts
    }
    RES_TYPE_REL {
        CHAR(12) parent_res_type PK, FK
        CHAR(12) child_res_type PK, FK
        CHAR(1) res_type_rel PK
        TIMESTAMP srcd_ts
    }
    RES {
        INTEGER res_id PK
        CHAR(12) res_type FK
        VARCHAR(128) res_code
        VARCHAR(100) res_name
        VARCHAR(20) res_short_name
        INTEGER site_id
        INTEGER support_ctr_id
        CHAR(6) res_tz_code
        INTEGER parent_res FK
        SMALLINT res_status
        TIMESTAMP srcd_ts
        VARCHAR(255) res_desc
    }
    RES_ALIAS {
        CHAR(12) res_type PK, FK
        VARCHAR(128) res_alias PK
        INTEGER res_id FK
        TIMESTAMP srcd_ts
    }
    RES_GRP {
        INTEGER res_grp_id PK
        VARCHAR(40) res_grp_name
        INTEGER parent_res_grp FK
        INTEGER group_level
        VARCHAR(250) group_path
        INTEGER client_id
        TIMESTAMP srcd_ts
        VARCHAR(200) res_grp_desc
    }
    RES_RESGRP {
        INTEGER res_grp_id PK, FK
        INTEGER res_id PK, FK
        TIMESTAMP srcd_ts
    }
    RES_TYPE ||--o{ RES_TYPE_REL : "may be child"
    RES_TYPE ||--o{ RES_TYPE_REL : "may parent"
    RES |o--o{ RES : "parent of"
    RES_TYPE ||--o{ RES : "classifies"
    RES ||--o{ RES_ALIAS : "is known as"
    RES_TYPE ||--o{ RES_ALIAS : "scopes"
    RES_GRP |o--o{ RES_GRP : "parent of"
    RES ||--o{ RES_RESGRP : "belongs to"
    RES_GRP ||--o{ RES_RESGRP : "has member"
```

- `RES.parent_res` and `RES_GRP.parent_res_grp` point at another row of
  the same table.
- `RES_TYPE_REL` lists which parent and child types may pair. No key
  enforces it on `RES.parent_res`; the loader checks it.
- `site_id`, `support_ctr_id` and `client_id` refer to tables the source
  diagrams don't show, so they carry no foreign key here.

---

## 2 · Metrics and aggregations

What was measured. A metric is a row in `METRIC`. `METRIC_SAMPLE` holds
one observation per resource, metric, provider and moment. The other three
tables are derived from it after every delivery.

```mermaid
erDiagram
    RES {
        INTEGER res_id PK
        CHAR(12) res_type FK
        INTEGER parent_res FK
    }
    METRIC {
        INTEGER metric_id PK
        CHAR(8) value_type FK
        VARCHAR(40) metric_code
        VARCHAR(160) metric_name
        VARCHAR(255) metric_desc
        VARCHAR(20) unit_of_measure
        TIMESTAMP srcd_ts
        INTEGER base_interval
        FLOAT gap_value
    }
    VALUE_TYPE {
        CHAR(8) value_type PK
        VARCHAR(100) value_type_desc
        TIMESTAMP srcd_ts
    }
    PROVIDER {
        INTEGER provider_id PK
        VARCHAR(64) provider_name
        TIMESTAMP srcd_ts
        CHAR(1) migration_src_fg
    }
    METRIC_SAMPLE {
        INTEGER res_id PK, FK
        INTEGER metric_id PK, FK
        TIMESTAMP sample_utc_ts PK
        INTEGER provider_id PK, FK
        FLOAT value
        CHAR(6) res_tz_code
        TIMESTAMP sample_lcl_ts
        SMALLINT srcd_d2k
    }
    METRIC_SUMMARY {
        INTEGER res_id PK, FK
        INTEGER metric_id PK, FK
        CHAR(1) summary_level PK
        TIMESTAMP start_utc_ts PK
        INTEGER provider_id PK, FK
        CHAR(6) res_tz_code
        TIMESTAMP start_lcl_ts
        INTEGER duration
        FLOAT value
        FLOAT value_max
        FLOAT value_min
        INTEGER value_cnt
        TIMESTAMP srcd_ts
    }
    METRIC_WEEKLY {
        INTEGER res_id PK, FK
        INTEGER metric_id PK, FK
        DATE start_lcl_dt PK
        INTEGER provider_id PK, FK
        CHAR(6) lcl_tz_code
        FLOAT value
        FLOAT value_max
        FLOAT value_min
        BIGINT value_cnt
        TIMESTAMP srcd_ts
    }
    RES_GRP {
        INTEGER res_grp_id PK
        INTEGER parent_res_grp FK
    }
    GRP_METRIC_WEEKLY {
        INTEGER res_id PK, FK
        INTEGER res_grp_id PK, FK
        INTEGER metric_id PK, FK
        DATE start_lcl_dt PK
        INTEGER provider_id PK, FK
        CHAR(6) lcl_tz_code
        DOUBLE value
        DOUBLE value_max
        DOUBLE value_min
        BIGINT value_cnt
        TIMESTAMP srcd_ts
    }
    VALUE_TYPE ||--o{ METRIC : "types"
    PROVIDER ||--o{ METRIC_SAMPLE : "reports"
    METRIC ||--o{ METRIC_SAMPLE : "is observed as"
    RES ||--o{ METRIC_SAMPLE : "is measured by"
    PROVIDER ||--o{ METRIC_SUMMARY : "reports"
    METRIC ||--o{ METRIC_SUMMARY : "is summarised as"
    RES ||--o{ METRIC_SUMMARY : "is summarised by"
    PROVIDER ||--o{ METRIC_WEEKLY : "reports"
    METRIC ||--o{ METRIC_WEEKLY : "rolls up as"
    RES ||--o{ METRIC_WEEKLY : "rolls up to"
    PROVIDER ||--o{ GRP_METRIC_WEEKLY : "reports"
    METRIC ||--o{ GRP_METRIC_WEEKLY : "rolls up as"
    RES_GRP ||--o{ GRP_METRIC_WEEKLY : "rolls up"
    RES ||--o{ GRP_METRIC_WEEKLY : "rolls up in"
```

---

## 3 · Calendar

One row per day for 2026 and 2027, with no foreign keys. The calendar-event
tables in the source diagrams are not built; the tag
`metrics-mart-with-calendar` has them.

```mermaid
erDiagram
    CALNDR {
        DATE calndr_date PK
        SMALLINT day_of_week
        SMALLINT occur_of_month
        SMALLINT last_occur_flag
        SMALLINT day_of_month
        SMALLINT month_end_flag
        SMALLINT week_of_year
        SMALLINT month
        SMALLINT year
        TIMESTAMP srcd_ts
    }
```

---

## 4 · Extensions for the shared corpus

Not in the source diagrams. `RES` has no column for an email, a signup
date, a currency, an order status or a placed-at time, so each resource
type that needs them gets a subtype table keyed on `res_id`, with its
codes in their own tables.

```mermaid
erDiagram
    RES {
        INTEGER res_id PK
        CHAR(12) res_type FK
        INTEGER parent_res FK
    }
    RES_CUSTOMER {
        INTEGER res_id PK, FK
        VARCHAR(128) email_addr
        DATE signup_date
        TIMESTAMP srcd_ts
    }
    RES_PRODUCT {
        INTEGER res_id PK, FK
        CHAR(3) currency_code FK
        TIMESTAMP srcd_ts
    }
    RES_ORDER {
        INTEGER res_id PK, FK
        CHAR(1) status_code FK
        CHAR(3) currency_code FK
        TIMESTAMP placed_at
        TIMESTAMP srcd_ts
    }
    ORDER_STATUS {
        CHAR(1) status_code PK
        VARCHAR(20) status_name
        TIMESTAMP srcd_ts
    }
    CURRENCY {
        CHAR(3) currency_code PK
        TIMESTAMP srcd_ts
    }
    RES ||--o| RES_CUSTOMER : "is a"
    CURRENCY |o--o{ RES_PRODUCT : "prices"
    RES ||--o| RES_PRODUCT : "is a"
    CURRENCY |o--o{ RES_ORDER : "prices"
    ORDER_STATUS |o--o{ RES_ORDER : "decodes"
    RES ||--o| RES_ORDER : "is a"
```

---

## 5 · Staging

The router fills these from the narrow landing on every delivery. They
hold names, not surrogates, so they have no foreign keys and no lines.
`METRIC_STG2` is `METRIC_STG` with every name resolved to an id.

```mermaid
erDiagram
    RES_STG {
        INTEGER batch_no
        CHAR(1) load_oper
        CHAR(12) res_type
        VARCHAR(128) res_code
        VARCHAR(100) res_name
        VARCHAR(20) res_short_name
        VARCHAR(128) parent_res_alias
        CHAR(12) parent_res_type
        VARCHAR(70) site_alias
        VARCHAR(20) support_ctr_code
        CHAR(6) res_tz_code
        SMALLINT res_status
        INTEGER sequence_no
        TIMESTAMP srcd_ts
        VARCHAR(255) res_desc
    }
    RES_ALIAS_STG {
        CHAR(12) res_type
        VARCHAR(128) res_alias
        VARCHAR(128) res_code
        TIMESTAMP srcd_ts
    }
    RES_RESGRP_STG {
        CHAR(12) res_type
        VARCHAR(128) res_alias
        VARCHAR(250) group_path
        TIMESTAMP srcd_ts
    }
    METRIC_STG {
        INTEGER batch_no
        CHAR(12) res_type
        VARCHAR(128) res_alias
        VARCHAR(40) metric_code
        VARCHAR(64) provider_name
        TIMESTAMP start_ts
        TIMESTAMP end_ts
        CHAR(6) sample_tz_code
        INTEGER duration
        FLOAT value
        FLOAT value_max
        FLOAT value_min
        INTEGER value_cnt
        CHAR(1) summary_level
        INTEGER sequence_no
        TIMESTAMP srcd_ts
    }
    METRIC_STG2 {
        INTEGER sequence_no
        INTEGER batch_no
        INTEGER res_id
        INTEGER metric_id
        TIMESTAMP start_utc_ts
        INTEGER provider_id
        CHAR(8) value_type
        CHAR(6) res_tz_code
        TIMESTAMP start_lcl_ts
        INTEGER duration
        CHAR(1) summary_level
        FLOAT value
        FLOAT value_max
        FLOAT value_min
        INTEGER value_cnt
        CHAR(6) sample_tz_code
        TIMESTAMP start_ts
        TIMESTAMP srcd_ts
    }
```

---

## Regenerating

The diagrams were generated from `PRAGMA table_info` and
`PRAGMA foreign_key_list` over a database built from `schema/`. If the
schema changes, regenerate them; don't edit the blocks by hand.
