-- =====================================================================
-- METRICS MART :: STAGING + 3NF CORE
-- ---------------------------------------------------------------------
-- Table and column names follow the source ER diagrams. Declared types
-- are the diagram's;
-- SQLite maps them to its own affinities.
--
-- Built:      staging, resource, metric, provider, group, aggregation
--             tables, and the CALNDR day table.
-- Not built:  TIME_ZONE, TZ_CODE, COUNTRY and RAW_RES_TYPE. They are
--             extensions to the model. Every *_tz_code is 'UTC'.
--             Calendar events (CALNDR_EVENT, CAL_EVT_TYPE, CAL_EVT_GRP)
--             were removed to keep the ten demos like for like; the tag
--             metrics-mart-with-calendar still has them.
-- Added:      a UNIQUE key on (res_type, res_code), metric_code,
--             provider_name and group_path; and three subtype tables
--             plus two code tables at the end of this file, because the
--             shared corpus carries attributes RES has no column for.
--
-- srcd_ts is read here as "when the mart last recorded a change to this
-- row" (the batch timestamp). srcd_d2k on METRIC_SAMPLE is read as the
-- same date in whole days since 2000-01-01. Both are assumptions.
-- =====================================================================

-- ------------------------------ STAGING ------------------------------
-- The router (scripts/route_stage.sh) fills these from the narrow
-- landing on every delivery. They hold the CURRENT delivery only.

CREATE TABLE metric_stg (
    batch_no       INTEGER      NOT NULL,
    res_type       CHAR(12)     NOT NULL,
    res_alias      VARCHAR(128) NOT NULL,
    metric_code    VARCHAR(40)  NOT NULL,
    provider_name  VARCHAR(64)  NOT NULL,
    start_ts       TIMESTAMP    NOT NULL,
    end_ts         TIMESTAMP,
    sample_tz_code CHAR(6)      NOT NULL,
    duration       INTEGER,
    value          FLOAT,
    value_max      FLOAT,
    value_min      FLOAT,
    value_cnt      INTEGER,
    summary_level  CHAR(1),
    sequence_no    INTEGER      NOT NULL,
    srcd_ts        TIMESTAMP    NOT NULL
);

-- METRIC_STG with every name resolved to its surrogate.
CREATE TABLE metric_stg2 (
    sequence_no    INTEGER,
    batch_no       INTEGER,
    res_id         INTEGER,
    metric_id      INTEGER,
    start_utc_ts   TIMESTAMP,
    provider_id    INTEGER,
    value_type     CHAR(8),
    res_tz_code    CHAR(6),
    start_lcl_ts   TIMESTAMP,
    duration       INTEGER,
    summary_level  CHAR(1),
    value          FLOAT,
    value_max      FLOAT,
    value_min      FLOAT,
    value_cnt      INTEGER,
    sample_tz_code CHAR(6),
    start_ts       TIMESTAMP,
    srcd_ts        TIMESTAMP NOT NULL
);

CREATE TABLE res_stg (
    batch_no         INTEGER      NOT NULL,
    load_oper        CHAR(1)      NOT NULL CHECK (load_oper IN ('U','D')),  -- upsert | delete
    res_type         CHAR(12)     NOT NULL,
    res_code         VARCHAR(128) NOT NULL,
    res_name         VARCHAR(100) NOT NULL,
    res_short_name   VARCHAR(20),
    parent_res_alias VARCHAR(128),
    parent_res_type  CHAR(12),
    site_alias       VARCHAR(70),
    support_ctr_code VARCHAR(20)  NOT NULL,
    res_tz_code      CHAR(6)      NOT NULL,
    res_status       SMALLINT,
    sequence_no      INTEGER      NOT NULL,
    srcd_ts          TIMESTAMP    NOT NULL,
    res_desc         VARCHAR(255)
);

CREATE TABLE res_alias_stg (
    res_type  CHAR(12)     NOT NULL,
    res_alias VARCHAR(128) NOT NULL,
    res_code  VARCHAR(128) NOT NULL,
    srcd_ts   TIMESTAMP    NOT NULL
);

CREATE TABLE res_resgrp_stg (
    res_type   CHAR(12)     NOT NULL,
    res_alias  VARCHAR(128) NOT NULL,
    group_path VARCHAR(250) NOT NULL,
    srcd_ts    TIMESTAMP    NOT NULL
);

-- ----------------------------- RESOURCE ------------------------------

CREATE TABLE res_type (
    res_type         CHAR(12)  NOT NULL PRIMARY KEY,
    res_type_desc    VARCHAR(100),
    autocrt_res_flag SMALLINT,          -- 1: a resource may be created from a reference alone
    srcd_ts          TIMESTAMP NOT NULL
);

-- Which parent/child pairings of resource types are allowed.
CREATE TABLE res_type_rel (
    parent_res_type CHAR(12)  NOT NULL REFERENCES res_type(res_type),
    child_res_type  CHAR(12)  NOT NULL REFERENCES res_type(res_type),
    res_type_rel    CHAR(1)   NOT NULL,
    srcd_ts         TIMESTAMP NOT NULL,
    PRIMARY KEY (parent_res_type, child_res_type, res_type_rel)
);

-- One row per resource, CURRENT STATE ONLY. The diagram gives RES no
-- validity columns, so a changed name or parent is an UPDATE in place
-- and a delete is res_status = 0. Earlier values live in the archive.
CREATE TABLE res (
    res_id         INTEGER      NOT NULL PRIMARY KEY,
    res_type       CHAR(12)     NOT NULL REFERENCES res_type(res_type),
    res_code       VARCHAR(128) NOT NULL,
    res_name       VARCHAR(100) NOT NULL,
    res_short_name VARCHAR(20),
    site_id        INTEGER,             -- FK to a table the diagrams don't show
    support_ctr_id INTEGER,             -- FK to a table the diagrams don't show
    res_tz_code    CHAR(6),
    parent_res     INTEGER REFERENCES res(res_id),
    res_status     SMALLINT     NOT NULL,   -- 1 live | 0 deleted
    srcd_ts        TIMESTAMP    NOT NULL,
    res_desc       VARCHAR(255),
    UNIQUE (res_type, res_code)
);

-- Identity resolution: every name any provider uses for a resource.
-- Metrics and parent references resolve to res_id through this table.
CREATE TABLE res_alias (
    res_type  CHAR(12)     NOT NULL REFERENCES res_type(res_type),
    res_alias VARCHAR(128) NOT NULL,
    res_id    INTEGER      NOT NULL REFERENCES res(res_id),
    srcd_ts   TIMESTAMP    NOT NULL,
    PRIMARY KEY (res_type, res_alias)
);

CREATE TABLE res_grp (
    res_grp_id     INTEGER      NOT NULL PRIMARY KEY,
    res_grp_name   VARCHAR(40)  NOT NULL,
    parent_res_grp INTEGER REFERENCES res_grp(res_grp_id),
    group_level    INTEGER,
    group_path     VARCHAR(250) NOT NULL UNIQUE,
    client_id      INTEGER,             -- FK to a table the diagrams don't show
    srcd_ts        TIMESTAMP    NOT NULL,
    res_grp_desc   VARCHAR(200)
);

CREATE TABLE res_resgrp (
    res_grp_id INTEGER   NOT NULL REFERENCES res_grp(res_grp_id),
    res_id     INTEGER   NOT NULL REFERENCES res(res_id),
    srcd_ts    TIMESTAMP NOT NULL,
    PRIMARY KEY (res_grp_id, res_id)
);

-- ------------------------------ METRICS ------------------------------

CREATE TABLE value_type (
    value_type      CHAR(8)   NOT NULL PRIMARY KEY,
    value_type_desc VARCHAR(100),
    srcd_ts         TIMESTAMP NOT NULL
);

-- A metric is a ROW here, not a column anywhere.
CREATE TABLE metric (
    metric_id       INTEGER     NOT NULL PRIMARY KEY,
    value_type      CHAR(8)     NOT NULL REFERENCES value_type(value_type),
    metric_code     VARCHAR(40) NOT NULL UNIQUE,
    metric_name     VARCHAR(160),
    metric_desc     VARCHAR(255),
    unit_of_measure VARCHAR(20),
    srcd_ts         TIMESTAMP   NOT NULL,
    base_interval   INTEGER,
    gap_value       FLOAT
);

CREATE TABLE provider (
    provider_id      INTEGER     NOT NULL PRIMARY KEY,
    provider_name    VARCHAR(64) NOT NULL UNIQUE,
    srcd_ts          TIMESTAMP   NOT NULL,
    migration_src_fg CHAR(1)     NOT NULL
);

-- One observation of one metric on one resource by one provider.
CREATE TABLE metric_sample (
    res_id        INTEGER   NOT NULL REFERENCES res(res_id),
    metric_id     INTEGER   NOT NULL REFERENCES metric(metric_id),
    sample_utc_ts TIMESTAMP NOT NULL,
    provider_id   INTEGER   NOT NULL REFERENCES provider(provider_id),
    value         FLOAT     NOT NULL,
    res_tz_code   CHAR(6)   NOT NULL,
    sample_lcl_ts TIMESTAMP,
    srcd_d2k      SMALLINT,
    PRIMARY KEY (res_id, metric_id, sample_utc_ts, provider_id)
);

-- Samples rolled up to a summary level. This demo derives level 'D'
-- (one UTC day); a provider could also deliver summaries directly.
CREATE TABLE metric_summary (
    res_id        INTEGER   NOT NULL REFERENCES res(res_id),
    metric_id     INTEGER   NOT NULL REFERENCES metric(metric_id),
    summary_level CHAR(1)   NOT NULL,
    start_utc_ts  TIMESTAMP NOT NULL,
    provider_id   INTEGER   NOT NULL REFERENCES provider(provider_id),
    res_tz_code   CHAR(6)   NOT NULL,
    start_lcl_ts  TIMESTAMP,
    duration      INTEGER   NOT NULL,
    value         FLOAT     NOT NULL,
    value_max     FLOAT,
    value_min     FLOAT,
    value_cnt     INTEGER   NOT NULL,
    srcd_ts       TIMESTAMP NOT NULL,
    PRIMARY KEY (res_id, metric_id, summary_level, start_utc_ts, provider_id)
);

-- ---------------------------- AGGREGATIONS ---------------------------

CREATE TABLE metric_weekly (
    res_id       INTEGER   NOT NULL REFERENCES res(res_id),
    metric_id    INTEGER   NOT NULL REFERENCES metric(metric_id),
    start_lcl_dt DATE      NOT NULL,        -- the Monday that starts the week
    provider_id  INTEGER   NOT NULL REFERENCES provider(provider_id),
    lcl_tz_code  CHAR(6)   NOT NULL,
    value        FLOAT     NOT NULL,
    value_max    FLOAT     NOT NULL,
    value_min    FLOAT     NOT NULL,
    value_cnt    BIGINT    NOT NULL,
    srcd_ts      TIMESTAMP NOT NULL,
    PRIMARY KEY (res_id, metric_id, start_lcl_dt, provider_id)
);

CREATE TABLE grp_metric_weekly (
    res_id       INTEGER   NOT NULL REFERENCES res(res_id),
    res_grp_id   INTEGER   NOT NULL REFERENCES res_grp(res_grp_id),
    metric_id    INTEGER   NOT NULL REFERENCES metric(metric_id),
    start_lcl_dt DATE      NOT NULL,
    provider_id  INTEGER   NOT NULL REFERENCES provider(provider_id),
    lcl_tz_code  CHAR(6)   NOT NULL,
    value        DOUBLE    NOT NULL,
    value_max    DOUBLE    NOT NULL,
    value_min    DOUBLE    NOT NULL,
    value_cnt    BIGINT    NOT NULL,
    srcd_ts      TIMESTAMP NOT NULL,
    PRIMARY KEY (res_id, res_grp_id, metric_id, start_lcl_dt, provider_id)
);

-- ------------------- NOT IN THE DIAGRAMS: EXTENSIONS ------------------
-- RES has a name, a short name and a description. The shared corpus
-- also carries an email, a signup date, a currency, an order status and
-- a placed-at time. In a 3NF model those go in subtype tables keyed on
-- res_id, with codes snowflaked out to their own tables.

CREATE TABLE order_status (            -- closed domain: an unknown code fails the load
    status_code CHAR(1)     NOT NULL PRIMARY KEY,
    status_name VARCHAR(20) NOT NULL,
    srcd_ts     TIMESTAMP   NOT NULL
);

CREATE TABLE currency (                -- open domain: the load adds new codes
    currency_code CHAR(3)   NOT NULL PRIMARY KEY,
    srcd_ts       TIMESTAMP NOT NULL
);

CREATE TABLE res_customer (
    res_id      INTEGER   NOT NULL PRIMARY KEY REFERENCES res(res_id),
    email_addr  VARCHAR(128),
    signup_date DATE,
    srcd_ts     TIMESTAMP NOT NULL
);

CREATE TABLE res_product (
    res_id        INTEGER   NOT NULL PRIMARY KEY REFERENCES res(res_id),
    currency_code CHAR(3) REFERENCES currency(currency_code),
    srcd_ts       TIMESTAMP NOT NULL
);

CREATE TABLE res_order (
    res_id        INTEGER   NOT NULL PRIMARY KEY REFERENCES res(res_id),
    status_code   CHAR(1) REFERENCES order_status(status_code),
    currency_code CHAR(3) REFERENCES currency(currency_code),
    placed_at     TIMESTAMP,
    srcd_ts       TIMESTAMP NOT NULL
);

-- ------------------------------ CALENDAR ------------------------------
-- One row per day, like dim_date in the Kimball demo.
--   day_of_week     1 = Monday .. 7 = Sunday
--   occur_of_month  1 for days 1-7, 2 for days 8-14, ... (the nth such weekday)
--   last_occur_flag 1 when it is the last such weekday of the month
CREATE TABLE calndr (
    calndr_date     DATE      NOT NULL PRIMARY KEY,
    day_of_week     SMALLINT  NOT NULL,
    occur_of_month  SMALLINT  NOT NULL,
    last_occur_flag SMALLINT,
    day_of_month    SMALLINT  NOT NULL,
    month_end_flag  SMALLINT  NOT NULL,
    week_of_year    SMALLINT  NOT NULL,
    month           SMALLINT  NOT NULL,
    year            SMALLINT  NOT NULL,
    srcd_ts         TIMESTAMP NOT NULL
);
